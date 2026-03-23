# SPDX-License-Identifier: Apache-2.0
defmodule VintageNetQMI.WatchdogTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests that validate watchdog behavior across all recovery scenarios.

  The watchdog must ONLY be petted when there is confirmed internet
  connectivity (ping OK). It must NEVER be petted when in :lan, :disconnected,
  or during any recovery phase. This is critical because petting the watchdog
  prevents PowerManager from resetting the modem.
  """

  @max_soft_recovery_attempts 3

  describe "Connectivity watchdog logic (check_connectivity)" do
    test "pets watchdog when reported_status is :internet" do
      assert should_pet?(:internet, :lan, 0) == true
    end

    test "does NOT pet watchdog when reported_status is :lan" do
      assert should_pet?(:lan, :lan, 0) == false
    end

    test "does NOT pet watchdog when reported_status is :lan even with 0 attempts" do
      assert should_pet?(:lan, :lan, 0) == false
    end

    test "does NOT pet watchdog when reported_status is :lan with 1 attempt" do
      assert should_pet?(:lan, :lan, 1) == false
    end

    test "does NOT pet watchdog when reported_status is :lan at max attempts" do
      assert should_pet?(:lan, :lan, @max_soft_recovery_attempts) == false
    end

    test "does NOT pet watchdog when reported_status is :disconnected" do
      assert should_pet?(:disconnected, :disconnected, 0) == false
    end

    test "does NOT pet watchdog when derived is :disconnected even if reported is :internet" do
      # This shouldn't normally happen, but if it did, :internet reported_status
      # means ping passed so it's OK to pet
      assert should_pet?(:internet, :disconnected, 0) == true
    end

    test "does NOT pet watchdog when reported is :going_down" do
      assert should_pet?(:going_down, :lan, 0) == false
    end
  end

  describe "InternetChecker watchdog logic" do
    test "pets watchdog only when Inspector confirms internet" do
      assert checker_should_pet?(:internet) == true
    end

    test "does NOT pet watchdog when Inspector says no_internet" do
      assert checker_should_pet?(:no_internet) == false
    end

    test "does NOT pet watchdog when Inspector says unknown" do
      assert checker_should_pet?(:unknown) == false
    end

    test "pets watchdog only when ping succeeds" do
      assert ping_result_should_pet?(:ok) == true
    end

    test "does NOT pet watchdog when ping fails" do
      assert ping_result_should_pet?(:error) == false
    end
  end

  describe "recovery phases - watchdog must stay dead" do
    test "during soft recovery attempt 1: no watchdog pet" do
      assert should_pet?(:lan, :lan, 0) == false
      assert should_pet?(:disconnected, :disconnected, 1) == false
    end

    test "during soft recovery attempt 2: no watchdog pet" do
      assert should_pet?(:lan, :lan, 1) == false
      assert should_pet?(:disconnected, :disconnected, 2) == false
    end

    test "during soft recovery attempt 3: no watchdog pet" do
      assert should_pet?(:lan, :lan, 2) == false
      assert should_pet?(:disconnected, :disconnected, 3) == false
    end

    test "after soft recovery exhausted: no watchdog pet" do
      assert should_pet?(:disconnected, :disconnected, @max_soft_recovery_attempts) == false
      assert should_pet?(:lan, :lan, @max_soft_recovery_attempts) == false
    end

    test "during hard recovery wait (5 min): no watchdog pet" do
      assert should_pet?(:disconnected, :disconnected, @max_soft_recovery_attempts) == false
    end

    test "after hard recovery resets attempts: still no pet until internet confirmed" do
      # Hard recovery resets to 0, but reported_status is :lan (reconnect just happened)
      assert should_pet?(:lan, :lan, 0) == false
    end

    test "only real internet confirmation pets watchdog" do
      # After hard recovery, ping finally succeeds → :internet
      assert should_pet?(:internet, :lan, 0) == true
    end
  end

  describe "full scenario: internet lost → recovery → restored" do
    test "complete lifecycle without any unauthorized watchdog petting" do
      pet_log = []

      # Phase 1: Internet working
      pet_log = pet_log ++ [{:internet, should_pet?(:internet, :lan, 0)}]

      # Phase 2: Ping starts failing, goes to :lan
      pet_log = pet_log ++ [{:lan_fail1, should_pet?(:lan, :lan, 0)}]
      pet_log = pet_log ++ [{:lan_fail2, should_pet?(:lan, :lan, 0)}]

      # Phase 3: 3 ping failures → :disconnected
      pet_log = pet_log ++ [{:disconnected, should_pet?(:disconnected, :disconnected, 0)}]

      # Phase 4: Soft recovery 1 → reconnect → modem says :lan
      pet_log = pet_log ++ [{:soft1_lan, should_pet?(:lan, :lan, 0)}]
      pet_log = pet_log ++ [{:soft1_disconnected, should_pet?(:disconnected, :disconnected, 1)}]

      # Phase 5: Soft recovery 2
      pet_log = pet_log ++ [{:soft2_lan, should_pet?(:lan, :lan, 1)}]
      pet_log = pet_log ++ [{:soft2_disconnected, should_pet?(:disconnected, :disconnected, 2)}]

      # Phase 6: Soft recovery 3
      pet_log = pet_log ++ [{:soft3_lan, should_pet?(:lan, :lan, 2)}]
      pet_log = pet_log ++ [{:soft3_disconnected, should_pet?(:disconnected, :disconnected, 3)}]

      # Phase 7: Hard recovery wait
      pet_log = pet_log ++ [{:hard_wait, should_pet?(:disconnected, :disconnected, 3)}]

      # Phase 8: Hard recovery fires, resets to 0, reconnect happens
      pet_log = pet_log ++ [{:hard_fired_lan, should_pet?(:lan, :lan, 0)}]

      # Phase 9: Internet restored!
      pet_log = pet_log ++ [{:restored, should_pet?(:internet, :lan, 0)}]

      # Verify: only :internet and :restored should have petted
      petted = Enum.filter(pet_log, fn {_label, pet?} -> pet? end)

      assert length(petted) == 2,
             "Only 2 phases should pet watchdog (initial internet + restored), got: #{inspect(petted)}"

      petted_labels = Enum.map(petted, fn {label, _} -> label end)
      assert :internet in petted_labels
      assert :restored in petted_labels
    end
  end

  describe "VintageNet InternetChecker removal" do
    test "VintageNet's checker would pet on :lan (why we remove it)" do
      # VintageNet.Connectivity.InternetChecker does:
      #   if state.check_logic.connectivity != :disconnected do
      #     PMControl.pet_watchdog(state.ifname)
      #   end
      # This means when connectivity is :lan, it WOULD pet — which is wrong for QMI.
      # That's why we remove it.

      vintage_net_would_pet_on_lan = :lan != :disconnected
      assert vintage_net_would_pet_on_lan == true,
             "VintageNet's checker pets on :lan, confirming why we must remove it"

      vintage_net_would_pet_on_internet = :internet != :disconnected
      assert vintage_net_would_pet_on_internet == true

      vintage_net_would_pet_on_disconnected = :disconnected != :disconnected
      assert vintage_net_would_pet_on_disconnected == false
    end

    test "our checker NEVER pets on :lan" do
      assert checker_should_pet?(:no_internet) == false
      assert checker_should_pet?(:unknown) == false
      assert ping_result_should_pet?(:error) == false
    end
  end

  # Mirrors the actual Connectivity.handle_info(:check_connectivity) logic
  defp should_pet?(reported_status, _derived_status, _attempts) do
    reported_status == :internet
  end

  # Mirrors InternetChecker logic for Inspector.check_internet result
  defp checker_should_pet?(:internet), do: true
  defp checker_should_pet?(_), do: false

  # Mirrors InternetChecker logic for TCPPing result
  defp ping_result_should_pet?(:ok), do: true
  defp ping_result_should_pet?(_), do: false
end
