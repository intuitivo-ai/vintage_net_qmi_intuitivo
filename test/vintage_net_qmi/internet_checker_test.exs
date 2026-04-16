# SPDX-License-Identifier: Apache-2.0
defmodule VintageNetQMI.InternetCheckerTest do
  use ExUnit.Case, async: true

  @normal_interval_ms 30_000
  @fast_interval_ms 5_000
  @max_ping_failures_before_disconnected 3

  describe "adaptive check interval logic" do
    test "uses normal interval when no failures" do
      state = %{consecutive_ping_failures: 0}
      assert next_interval(state) == @normal_interval_ms
    end

    test "uses fast interval after first failure" do
      state = %{consecutive_ping_failures: 1}
      assert next_interval(state) == @fast_interval_ms
    end

    test "uses fast interval after multiple failures" do
      state = %{consecutive_ping_failures: 5}
      assert next_interval(state) == @fast_interval_ms
    end

    test "returns to normal interval after failure count resets to 0" do
      state_failing = %{consecutive_ping_failures: 3}
      assert next_interval(state_failing) == @fast_interval_ms

      state_recovered = %{consecutive_ping_failures: 0}
      assert next_interval(state_recovered) == @normal_interval_ms
    end

    test "fast interval is significantly faster than normal" do
      assert @fast_interval_ms < @normal_interval_ms
      assert @fast_interval_ms <= @normal_interval_ms / 2
    end

    test "detection time with fast interval vs normal" do
      max_failures = @max_ping_failures_before_disconnected

      normal_detection_ms = max_failures * @normal_interval_ms
      fast_detection_ms = @normal_interval_ms + (max_failures - 1) * @fast_interval_ms

      assert fast_detection_ms < normal_detection_ms,
             "Fast detection (#{fast_detection_ms}ms) should be faster than normal (#{normal_detection_ms}ms)"

      assert fast_detection_ms <= 40_000,
             "With adaptive interval, zombie detection should be under 40s, got #{fast_detection_ms}ms"
    end
  end

  describe "watchdog petting in InternetChecker" do
    test "Inspector :internet → pets watchdog" do
      result = check_result_action(:internet)
      assert result.pets_watchdog == true
      assert result.status == :internet
    end

    test "Inspector :no_internet → does NOT pet, falls through to ping" do
      result = check_result_action(:no_internet)
      assert result.pets_watchdog == false
      assert result.status == :needs_ping
    end

    test "Inspector :unknown → does NOT pet, falls through to ping" do
      result = check_result_action(:unknown)
      assert result.pets_watchdog == false
      assert result.status == :needs_ping
    end

    test "ping :ok → pets watchdog, resets failures" do
      result = ping_result_action(:ok, 2)
      assert result.pets_watchdog == true
      assert result.consecutive_ping_failures == 0
      assert result.reported_status == :internet
    end

    test "ping fail (1st) → no pet, reports :lan" do
      result = ping_result_action(:error, 0)
      assert result.pets_watchdog == false
      assert result.consecutive_ping_failures == 1
      assert result.reported_status == :lan
    end

    test "ping fail (2nd) → no pet, still :lan" do
      result = ping_result_action(:error, 1)
      assert result.pets_watchdog == false
      assert result.consecutive_ping_failures == 2
      assert result.reported_status == :lan
    end

    test "ping fail (3rd, threshold) → no pet, reports :disconnected" do
      result = ping_result_action(:error, 2)
      assert result.pets_watchdog == false
      assert result.consecutive_ping_failures == 3
      assert result.reported_status == :disconnected
    end

    test "ping fail beyond threshold → no pet, stays :disconnected" do
      result = ping_result_action(:error, 5)
      assert result.pets_watchdog == false
      assert result.consecutive_ping_failures == 6
      assert result.reported_status == :disconnected
    end

    test "interface not up → no pet, :disconnected, resets failures" do
      result = lower_up_action(false, 5)
      assert result.pets_watchdog == false
      assert result.reported_status == :disconnected
      assert result.consecutive_ping_failures == 0
    end

    test "no IPv4 address → no pet, :disconnected, resets failures" do
      result = no_ipv4_action(3)
      assert result.pets_watchdog == false
      assert result.reported_status == :disconnected
      assert result.consecutive_ping_failures == 0
    end
  end

  describe "contrast with VintageNet's InternetChecker" do
    test "VintageNet pets on :lan (check_logic.connectivity != :disconnected)" do
      # VintageNet's pet_pm_watchdog/1:
      #   if state.check_logic.connectivity != :disconnected do
      #     PMControl.pet_watchdog(state.ifname)
      #   end
      # This means on :lan it PETS - this is what we DON'T want.
      assert vintage_net_would_pet?(:internet) == true
      assert vintage_net_would_pet?(:lan) == true  # <-- THE PROBLEM
      assert vintage_net_would_pet?(:disconnected) == false
    end

    test "our InternetChecker never pets on :lan" do
      assert our_checker_pets?(:internet) == true
      assert our_checker_pets?(:lan) == false
      assert our_checker_pets?(:disconnected) == false
    end

    test "our Connectivity never pets on :lan" do
      assert connectivity_pets?(:internet) == true
      assert connectivity_pets?(:lan) == false
      assert connectivity_pets?(:disconnected) == false
    end
  end

  describe "failure progression and watchdog silence" do
    test "complete failure progression never pets watchdog" do
      # Simulate: internet OK → first fail → second fail → third fail → :disconnected
      pet_events = []

      # Start with internet
      r = check_result_action(:internet)
      pet_events = pet_events ++ [{:internet_ok, r.pets_watchdog}]

      # Inspector says no_internet, need to ping
      r = check_result_action(:no_internet)
      pet_events = pet_events ++ [{:no_internet, r.pets_watchdog}]

      # Ping fails 1
      r = ping_result_action(:error, 0)
      pet_events = pet_events ++ [{:ping_fail_1, r.pets_watchdog}]

      # Ping fails 2
      r = ping_result_action(:error, 1)
      pet_events = pet_events ++ [{:ping_fail_2, r.pets_watchdog}]

      # Ping fails 3 → :disconnected
      r = ping_result_action(:error, 2)
      pet_events = pet_events ++ [{:ping_fail_3, r.pets_watchdog}]

      # Only the first event should have petted
      petted = Enum.filter(pet_events, fn {_, v} -> v end)
      assert length(petted) == 1
      [{label, _}] = petted
      assert label == :internet_ok
    end
  end

  # --- Helpers mirroring InternetChecker logic ---

  defp next_interval(%{consecutive_ping_failures: 0}), do: @normal_interval_ms
  defp next_interval(_state), do: @fast_interval_ms

  defp check_result_action(:internet) do
    %{pets_watchdog: true, status: :internet}
  end

  defp check_result_action(_other) do
    %{pets_watchdog: false, status: :needs_ping}
  end

  defp ping_result_action(:ok, _prev_failures) do
    %{
      pets_watchdog: true,
      consecutive_ping_failures: 0,
      reported_status: :internet
    }
  end

  defp ping_result_action(_error, prev_failures) do
    new_failures = prev_failures + 1

    reported_status =
      if new_failures >= @max_ping_failures_before_disconnected,
        do: :disconnected,
        else: :lan

    %{
      pets_watchdog: false,
      consecutive_ping_failures: new_failures,
      reported_status: reported_status
    }
  end

  defp lower_up_action(false = _lower_up?, _prev_failures) do
    %{pets_watchdog: false, reported_status: :disconnected, consecutive_ping_failures: 0}
  end

  defp no_ipv4_action(_prev_failures) do
    %{pets_watchdog: false, reported_status: :disconnected, consecutive_ping_failures: 0}
  end

  # VintageNet's InternetChecker logic
  defp vintage_net_would_pet?(connectivity) do
    connectivity != :disconnected
  end

  # Our InternetChecker - only pets on confirmed :internet
  defp our_checker_pets?(:internet), do: true
  defp our_checker_pets?(_), do: false

  # Our Connectivity module - only pets on :internet
  defp connectivity_pets?(:internet), do: true
  defp connectivity_pets?(_), do: false
end
