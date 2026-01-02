# SPDX-FileCopyrightText: 2026 Intuitivo
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule VintageNetQMI.InternetChecker do
  @moduledoc false

  use GenServer

  alias VintageNet.Connectivity.{HostList, Inspector, TCPPing}
  alias VintageNet.PowerManager.PMControl
  alias VintageNet.RouteManager

  require Logger

  @initial_check_ms 5_000
  @interval_ms 30_000

  @type state :: %{
          ifname: VintageNet.ifname(),
          inspector: Inspector.cache(),
          configured_hosts: [{VintageNet.any_ip_address(), non_neg_integer()}],
          ping_list: [{:inet.ip_address(), non_neg_integer()}]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    ifname = Keyword.fetch!(opts, :ifname)
    GenServer.start_link(__MODULE__, ifname)
  end

  @impl GenServer
  def init(ifname) do
    state = %{
      ifname: ifname,
      inspector: %{},
      configured_hosts: HostList.load(),
      ping_list: []
    }

    {:ok, state, {:continue, :continue}}
  end

  @impl GenServer
  def handle_continue(:continue, %{ifname: ifname} = state) do
    VintageNet.subscribe(["interface", ifname, "lower_up"])
    VintageNet.subscribe(["interface", ifname, "addresses"])

    {:noreply, state, @initial_check_ms}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    new_state = check_connectivity(state)
    {:noreply, new_state, @interval_ms}
  end

  def handle_info({_vn, ["interface", ifname, "lower_up"], _old, _new, _meta}, %{ifname: ifname} = state) do
    # Re-check quickly on link changes
    {:noreply, state, 0}
  end

  def handle_info({_vn, ["interface", ifname, "addresses"], _old, _new, _meta}, %{ifname: ifname} = state) do
    # Re-check quickly on address changes
    {:noreply, state, 0}
  end

  def handle_info(_msg, state), do: {:noreply, state, @interval_ms}

  defp check_connectivity(%{ifname: ifname} = state) do
    lower_up? = VintageNet.get(["interface", ifname, "lower_up"]) == true

    cond do
      not lower_up? ->
        # If the interface isn't up, it's definitely disconnected.
        RouteManager.set_connection_status(ifname, :disconnected, "qmi_ifdown")
        %{state | inspector: %{}, ping_list: []}

      not has_ipv4_address?(VintageNet.get(["interface", ifname, "addresses"])) ->
        # For QMI, if we don't even have IPv4, treat it as disconnected. This
        # prevents "LAN (timeout)" behavior when there's no SIM/no DHCP lease.
        RouteManager.set_connection_status(ifname, :disconnected, "qmi_no_ipv4")
        %{state | inspector: %{}, ping_list: []}

      true ->
        # 1) Try to infer internet from TCP activity
        {status, new_cache} = Inspector.check_internet(ifname, state.inspector)
        state = %{state | inspector: new_cache}

        case status do
          :internet ->
            RouteManager.set_connection_status(ifname, :internet, "qmi_inspector")
            PMControl.pet_watchdog(ifname)
            state

          :no_internet ->
            # No IPv4 would have been caught above; keep calm and don't override
            # QMI-derived status to :lan here.
            maybe_ping_for_internet(state)

          :unknown ->
            maybe_ping_for_internet(state)
        end
    end
  end

  defp maybe_ping_for_internet(state) do
    state
    |> reload_ping_list()
    |> ping_once()
  end

  defp reload_ping_list(%{ping_list: []} = state) do
    ping_list =
      HostList.create_ping_list(state.configured_hosts)
      |> Enum.filter(fn {ip, _port} -> Inspector.routed_address?(state.ifname, ip) end)

    %{state | ping_list: ping_list}
  end

  defp reload_ping_list(state), do: state

  defp ping_once(%{ping_list: []} = state) do
    # No ping hosts available, but we have IP and lower_up.
    # Fallback to :lan status so we don't get stuck in :disconnected.
    RouteManager.set_connection_status(state.ifname, :lan, "qmi_no_ping_hosts")
    state
  end

  defp ping_once(%{ping_list: [{ip, port} | rest]} = state) do
    case TCPPing.ping(state.ifname, {ip, port}) do
      :ok ->
        RouteManager.set_connection_status(state.ifname, :internet, "qmi_ping")
        PMControl.pet_watchdog(state.ifname)
        %{state | ping_list: rest}

      other ->
        Logger.debug("[VintageNetQMI] internet ping failed on #{state.ifname}: #{inspect(other)}")
        # If ping explicitly fails, downgrade to :lan so Connectivity can handle recovery
        RouteManager.set_connection_status(state.ifname, :lan, "qmi_ping_failed")
        %{state | ping_list: rest}
    end
  end

  defp has_ipv4_address?(nil), do: false

  defp has_ipv4_address?(addresses) do
    Enum.any?(addresses, fn
      %{family: :inet} -> true
      _ -> false
    end)
  end
end
