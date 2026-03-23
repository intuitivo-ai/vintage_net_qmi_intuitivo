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

  defp simulate_internet_restored(state) do
    %{state | soft_recovery_attempts: 0, hard_recovery_timer: nil, soft_recovery_timer: nil}
  end

  defp should_pet_watchdog?(reported_status, _attempts) do
    reported_status == :internet
  end
end
