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
  @normal_interval_ms 30_000
  @fast_interval_ms 5_000
  @max_ping_failures_before_disconnected 3

  @type state :: %{
          ifname: VintageNet.ifname(),
          inspector: Inspector.cache(),
          configured_hosts: [{VintageNet.any_ip_address(), non_neg_integer()}],
          ping_list: [{:inet.ip_address(), non_neg_integer()}],
          consecutive_ping_failures: non_neg_integer()
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
      ping_list: [],
      consecutive_ping_failures: 0
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
    {:noreply, new_state, next_interval(new_state)}
  end

  def handle_info({_vn, ["interface", ifname, "lower_up"], _old, _new, _meta}, %{ifname: ifname} = state) do
    # Re-check quickly on link changes
    {:noreply, state, 0}
  end

  def handle_info({_vn, ["interface", ifname, "addresses"], _old, _new, _meta}, %{ifname: ifname} = state) do
    # Re-check quickly on address changes
    {:noreply, state, 0}
  end

  def handle_info(_msg, state), do: {:noreply, state, next_interval(state)}

  defp check_connectivity(%{ifname: ifname} = state) do
    lower_up? = VintageNet.get(["interface", ifname, "lower_up"]) == true

    cond do
      not lower_up? ->
        # If the interface isn't up, it's definitely disconnected.
        # Reset consecutive_ping_failures so we start fresh when interface comes back up
        RouteManager.set_connection_status(ifname, :disconnected, "qmi_ifdown")
        %{state | inspector: %{}, ping_list: [], consecutive_ping_failures: 0}

      not has_ipv4_address?(VintageNet.get(["interface", ifname, "addresses"])) ->
        # For QMI, if we don't even have IPv4, treat it as disconnected. This
        # prevents "LAN (timeout)" behavior when there's no SIM/no DHCP lease.
        # Reset consecutive_ping_failures so we start fresh when IP is assigned
        RouteManager.set_connection_status(ifname, :disconnected, "qmi_no_ipv4")
        %{state | inspector: %{}, ping_list: [], consecutive_ping_failures: 0}

      true ->
        # 1) Try to infer internet from TCP activity
        {status, new_cache} = Inspector.check_internet(ifname, state.inspector)
        state = %{state | inspector: new_cache}

        case status do
          :internet ->
            RouteManager.set_connection_status(ifname, :internet, "qmi_inspector")
            PMControl.pet_watchdog(ifname)
            # Reset consecutive ping failures since we have internet
            %{state | consecutive_ping_failures: 0}

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
        # Reset consecutive failures on success
        %{state | ping_list: rest, consecutive_ping_failures: 0}

      other ->
        new_failures = state.consecutive_ping_failures + 1
        Logger.debug("[VintageNetQMI] internet ping failed on #{state.ifname}: #{inspect(other)} (consecutive: #{new_failures})")

        # After @max_ping_failures_before_disconnected consecutive failures,
        # report :disconnected instead of :lan so watchdog is NOT petted
        if new_failures >= @max_ping_failures_before_disconnected do
          Logger.warning("[VintageNetQMI] #{state.ifname}: #{new_failures} consecutive ping failures, reporting :disconnected")
          RouteManager.set_connection_status(state.ifname, :disconnected, "qmi_ping_failed_#{new_failures}x")
        else
          # Still within tolerance, report :lan so Connectivity can handle recovery
          RouteManager.set_connection_status(state.ifname, :lan, "qmi_ping_failed")
        end

        %{state | ping_list: rest, consecutive_ping_failures: new_failures}
    end
  end

  defp next_interval(%{consecutive_ping_failures: 0}), do: @normal_interval_ms
  defp next_interval(_state), do: @fast_interval_ms

  defp has_ipv4_address?(nil), do: false

  defp has_ipv4_address?(addresses) do
    Enum.any?(addresses, fn
      %{family: :inet} -> true
      _ -> false
    end)
  end
end
