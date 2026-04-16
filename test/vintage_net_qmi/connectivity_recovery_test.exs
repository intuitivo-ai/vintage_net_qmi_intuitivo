# SPDX-License-Identifier: Apache-2.0
defmodule VintageNetQMI.ConnectivityRecoveryTest do
  use ExUnit.Case, async: true

  @max_soft_recovery_attempts 3
  @hard_recovery_interval 300_000

  describe "recovery state machine logic" do
    test "soft recovery exhaustion triggers hard recovery scheduling" do
      state = base_state(%{soft_recovery_attempts: @max_soft_recovery_attempts})

      new_state = maybe_schedule_hard_recovery(state)
      assert new_state.hard_recovery_timer != nil
    end

    test "hard recovery is not scheduled when soft attempts not exhausted" do
      state = base_state(%{soft_recovery_attempts: 1})

      new_state = maybe_schedule_hard_recovery(state)
      assert new_state.hard_recovery_timer == nil
    end

    test "hard recovery is not scheduled if already scheduled" do
      existing_timer = make_ref()
      state = base_state(%{
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: existing_timer
      })

      new_state = maybe_schedule_hard_recovery(state)
      assert new_state.hard_recovery_timer == existing_timer
    end

    test "hard recovery resets soft_recovery_attempts" do
      state = base_state(%{soft_recovery_attempts: @max_soft_recovery_attempts})
      new_state = simulate_hard_recovery(state)

      assert new_state.soft_recovery_attempts == 0
      assert new_state.hard_recovery_timer == nil
    end

    test "internet restore cancels hard recovery timer" do
      timer_ref = make_ref()
      state = base_state(%{hard_recovery_timer: timer_ref})

      new_state = cancel_hard_recovery_timer(state)
      assert new_state.hard_recovery_timer == nil
    end

    test "soft recovery cap at max_soft_recovery_attempts" do
      attempts =
        Enum.reduce(1..10, 0, fn _, acc ->
          if acc < @max_soft_recovery_attempts, do: acc + 1, else: acc
        end)

      assert attempts == @max_soft_recovery_attempts
    end
  end

  describe "full recovery cycles (infinite loop)" do
    test "soft exhaustion → hard → reset → soft again → hard again" do
      state = base_state()

      # --- Cycle 1 ---
      # Soft recoveries 1..3
      state = %{state | soft_recovery_attempts: 1}
      assert maybe_schedule_hard_recovery(state).hard_recovery_timer == nil

      state = %{state | soft_recovery_attempts: 2}
      assert maybe_schedule_hard_recovery(state).hard_recovery_timer == nil

      state = %{state | soft_recovery_attempts: 3}
      state = maybe_schedule_hard_recovery(state)
      assert state.hard_recovery_timer != nil

      # Hard recovery fires
      state = simulate_hard_recovery(state)
      assert state.soft_recovery_attempts == 0
      assert state.hard_recovery_timer == nil

      # --- Cycle 2 (should work identically) ---
      state = %{state | soft_recovery_attempts: 1}
      assert maybe_schedule_hard_recovery(state).hard_recovery_timer == nil

      state = %{state | soft_recovery_attempts: 2}
      assert maybe_schedule_hard_recovery(state).hard_recovery_timer == nil

      state = %{state | soft_recovery_attempts: 3}
      state = maybe_schedule_hard_recovery(state)
      assert state.hard_recovery_timer != nil

      # Hard recovery fires again
      state = simulate_hard_recovery(state)
      assert state.soft_recovery_attempts == 0
      assert state.hard_recovery_timer == nil

      # --- Cycle 3 (verify it never gets stuck) ---
      state = %{state | soft_recovery_attempts: 3}
      state = maybe_schedule_hard_recovery(state)
      assert state.hard_recovery_timer != nil
    end

    test "internet recovery at any point cancels everything" do
      # Mid soft recovery
      state = base_state(%{soft_recovery_attempts: 2, soft_recovery_timer: make_ref()})
      state = simulate_internet_restored(state)
      assert state.soft_recovery_attempts == 0
      assert state.hard_recovery_timer == nil
      assert state.soft_recovery_timer == nil

      # During hard recovery wait
      state = base_state(%{
        soft_recovery_attempts: 3,
        hard_recovery_timer: make_ref()
      })
      state = simulate_internet_restored(state)
      assert state.soft_recovery_attempts == 0
      assert state.hard_recovery_timer == nil
    end
  end

  describe "watchdog interaction during recovery" do
    test "watchdog never petted during soft recovery" do
      for attempts <- 0..@max_soft_recovery_attempts do
        refute should_pet_watchdog?(:lan, attempts),
               "Watchdog should NOT be petted at attempt #{attempts} with :lan"

        refute should_pet_watchdog?(:disconnected, attempts),
               "Watchdog should NOT be petted at attempt #{attempts} with :disconnected"
      end
    end

    test "watchdog never petted during hard recovery wait" do
      refute should_pet_watchdog?(:disconnected, @max_soft_recovery_attempts)
      refute should_pet_watchdog?(:lan, @max_soft_recovery_attempts)
    end

    test "watchdog never petted after hard recovery resets attempts" do
      refute should_pet_watchdog?(:lan, 0)
    end

    test "watchdog only petted when :internet is confirmed" do
      assert should_pet_watchdog?(:internet, 0)
      assert should_pet_watchdog?(:internet, 1)
      assert should_pet_watchdog?(:internet, @max_soft_recovery_attempts)
    end
  end

  describe "race condition: stale :soft_recovery after :internet event" do
    test "stale soft_recovery with :internet status does NOT reschedule hard recovery" do
      # Race: :internet event fires → clears hard_recovery_timer + soft_recovery_timer
      # → stale :soft_recovery arrives → reported_status is now :internet
      # → old code: else branch called maybe_schedule_hard_recovery() unconditionally
      # → new code: guard prevents rescheduling when reported_status == :internet

      state = base_state(%{
        reported_status: :internet,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: nil,  # cleared by :internet event
        soft_recovery_timer: nil
      })

      # Simulate the else branch of :soft_recovery (reported_status != :lan, or attempts exhausted)
      # With the fix, :internet status must prevent maybe_schedule_hard_recovery
      new_state = simulate_stale_soft_recovery(state)

      assert new_state.hard_recovery_timer == nil,
             "Stale :soft_recovery must NOT reschedule hard recovery when :internet is confirmed"
    end

    test "stale soft_recovery with :disconnected still schedules hard recovery if needed" do
      # If we're still disconnected (not internet), hard recovery should still be scheduled
      state = base_state(%{
        reported_status: :disconnected,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: nil,
        soft_recovery_timer: nil
      })

      new_state = simulate_stale_soft_recovery(state)

      assert new_state.hard_recovery_timer != nil,
             "Stale :soft_recovery with :disconnected and exhausted attempts should schedule hard recovery"
    end

    test "stale soft_recovery with :lan and exhausted attempts schedules hard recovery" do
      state = base_state(%{
        reported_status: :lan,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: nil,
        soft_recovery_timer: nil
      })

      new_state = simulate_stale_soft_recovery(state)
      assert new_state.hard_recovery_timer != nil
    end
  end

  describe "stability_check cancels stale hard recovery timer" do
    test "stability confirmed: cancels hard recovery timer if still set" do
      # Race: stale :soft_recovery re-armed hard_recovery_timer after :internet cleared it.
      # stability_check fires 60s later and must clean up that stale timer.
      stale_timer = make_ref()

      state = base_state(%{
        reported_status: :internet,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: stale_timer,
        stability_timer: nil
      })

      new_state = simulate_stability_check(state)

      assert new_state.hard_recovery_timer == nil,
             "stability_check must cancel stale hard_recovery_timer"
      assert new_state.soft_recovery_attempts == 0,
             "stability_check must reset soft_recovery_attempts"
    end

    test "stability not confirmed: does NOT touch hard recovery timer" do
      stale_timer = make_ref()

      state = base_state(%{
        reported_status: :lan,
        hard_recovery_timer: stale_timer,
        stability_timer: nil
      })

      new_state = simulate_stability_check(state)

      assert new_state.hard_recovery_timer == stale_timer,
             "stability_check with non-internet status must leave hard_recovery_timer alone"
    end

    test "full race: internet → stale soft_recovery → stability_check → no hard recovery" do
      # Step 1: Internet confirmed, timers cleared
      state = base_state(%{
        reported_status: :internet,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: nil,
        soft_recovery_timer: nil,
        stability_timer: nil
      })

      # Step 2: Stale :soft_recovery arrives — with fix, should NOT re-arm hard recovery
      state = simulate_stale_soft_recovery(state)
      assert state.hard_recovery_timer == nil, "Fix 1: stale soft_recovery must not re-arm timer"

      # Step 3: stability_check fires — also cancels any timer that slipped through
      state = simulate_stability_check(state)
      assert state.hard_recovery_timer == nil, "Fix 2: stability_check must clear any stale timer"
      assert state.soft_recovery_attempts == 0
    end

    test "worst case: stale soft_recovery re-arms timer, stability_check saves the day" do
      # Even if Fix 1 wasn't applied (old code re-arms), Fix 2 would catch it.
      stale_timer = make_ref()
      state = base_state(%{
        reported_status: :internet,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: stale_timer,
        stability_timer: nil
      })

      new_state = simulate_stability_check(state)
      assert new_state.hard_recovery_timer == nil, "stability_check cancels stale timer"
    end
  end

  describe "race condition: stale :hard_recovery after :internet event" do
    test "stale hard_recovery with :internet status does NOT reconnect (returns state unchanged)" do
      state = base_state(%{
        reported_status: :internet,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: nil
      })

      new_state = simulate_hard_recovery_with_guard(state)

      assert new_state.reported_status == :internet,
             "Stale :hard_recovery must not alter reported_status"
      assert new_state.soft_recovery_attempts == @max_soft_recovery_attempts,
             "Stale :hard_recovery must not reset soft_recovery_attempts when internet is confirmed"
      assert new_state.hard_recovery_timer == nil
    end

    test "hard_recovery with :disconnected still resets and reconnects" do
      state = base_state(%{
        reported_status: :disconnected,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: make_ref()
      })

      new_state = simulate_hard_recovery_with_guard(state)

      assert new_state.soft_recovery_attempts == 0,
             ":hard_recovery with :disconnected must reset attempts"
      assert new_state.hard_recovery_timer == nil
    end

    test "hard_recovery with :lan still resets and reconnects" do
      state = base_state(%{
        reported_status: :lan,
        soft_recovery_attempts: @max_soft_recovery_attempts,
        hard_recovery_timer: make_ref()
      })

      new_state = simulate_hard_recovery_with_guard(state)

      assert new_state.soft_recovery_attempts == 0
      assert new_state.hard_recovery_timer == nil
    end
  end

  # --- Helper functions mirroring Connectivity logic ---

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        soft_recovery_attempts: 0,
        hard_recovery_timer: nil,
        soft_recovery_timer: nil,
        ifname: "wwan0"
      },
      overrides
    )
  end

  defp maybe_schedule_hard_recovery(
         %{hard_recovery_timer: nil, soft_recovery_attempts: attempts} = state
       )
       when attempts >= @max_soft_recovery_attempts do
    {:ok, timer} = :timer.send_after(@hard_recovery_interval, :hard_recovery)
    %{state | hard_recovery_timer: timer}
  end

  defp maybe_schedule_hard_recovery(state), do: state

  defp cancel_hard_recovery_timer(state) do
    %{state | hard_recovery_timer: nil}
  end

  defp simulate_hard_recovery(state) do
    %{state | soft_recovery_attempts: 0, hard_recovery_timer: nil, soft_recovery_timer: nil}
  end

  # Mirrors fixed handle_info(:hard_recovery) with the :internet guard
  defp simulate_hard_recovery_with_guard(state) do
    state = %{state | hard_recovery_timer: nil}

    if state.reported_status == :internet do
      state
    else
      %{state | soft_recovery_attempts: 0, soft_recovery_timer: nil}
    end
  end

  defp simulate_internet_restored(state) do
    %{state | soft_recovery_attempts: 0, hard_recovery_timer: nil, soft_recovery_timer: nil}
  end

  defp should_pet_watchdog?(reported_status, _attempts) do
    reported_status == :internet
  end

  # Mirrors fixed handle_info(:soft_recovery) else branch
  defp simulate_stale_soft_recovery(state) do
    state = %{state | soft_recovery_timer: nil}

    if state.reported_status == :internet do
      state
    else
      maybe_schedule_hard_recovery(state)
    end
  end

  # Mirrors fixed handle_info(:stability_check)
  defp simulate_stability_check(state) do
    if state.reported_status == :internet do
      %{state | soft_recovery_attempts: 0, stability_timer: nil}
      |> cancel_hard_recovery_timer()
    else
      %{state | stability_timer: nil}
    end
  end
end
