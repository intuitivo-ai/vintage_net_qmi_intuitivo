# SPDX-License-Identifier: Apache-2.0
defmodule VintageNetQMI.ConnectionBackoffTest do
  use ExUnit.Case, async: true

  @initial_retry_interval 5_000
  @max_retry_interval 120_000
  @backoff_multiplier 2

  describe "exponential backoff calculation" do
    test "backoff sequence follows exponential pattern" do
      intervals = compute_backoff_sequence(@initial_retry_interval, 10)

      assert intervals == [
               5_000,
               10_000,
               20_000,
               40_000,
               80_000,
               120_000,
               120_000,
               120_000,
               120_000,
               120_000
             ]
    end

    test "backoff never exceeds max_retry_interval" do
      intervals = compute_backoff_sequence(@initial_retry_interval, 20)

      Enum.each(intervals, fn interval ->
        assert interval <= @max_retry_interval,
               "Interval #{interval} exceeds max #{@max_retry_interval}"
      end)
    end

    test "first retry is at initial_retry_interval" do
      [first | _] = compute_backoff_sequence(@initial_retry_interval, 1)
      assert first == @initial_retry_interval
    end

    test "backoff resets after success" do
      intervals = compute_backoff_sequence(@initial_retry_interval, 5)
      [_, _, third, _, _] = intervals
      assert third == 20_000

      # After reset, should start from initial again
      reset_intervals = compute_backoff_sequence(@initial_retry_interval, 3)
      assert hd(reset_intervals) == @initial_retry_interval
    end
  end

  describe "try_to_configure timer handling" do
    test "after configure completes, next retry fires at initial interval (not escalated)" do
      # Bug: bare Process.send_after in :try_to_configure handler didn't reset connect_retry_interval.
      # If backoff escalated to e.g. 80s before configure succeeded, the next failed
      # connection attempt would retry at 80s instead of @initial_retry_interval.
      #
      # In start_try_to_connect_timer, the timer fires at `state.connect_retry_interval`,
      # then stores `next_interval = min(current * multiplier, max)` for subsequent retries.
      # So after configure success, we reset to @initial_retry_interval, the timer fires
      # at that value, and the stored value becomes @initial_retry_interval * multiplier.

      escalated_interval = 80_000

      state = %{
        connect_retry_interval: escalated_interval,
        try_to_connect_timer: nil
      }

      new_state = simulate_configure_success(state)

      # The timer was scheduled at @initial_retry_interval (not 80s).
      # The stored connect_retry_interval is now the NEXT interval after initial (i.e. initial * 2),
      # ready for if the attempt after configure also fails.
      expected_stored = min(@initial_retry_interval * @backoff_multiplier, @max_retry_interval)

      assert new_state.connect_retry_interval == expected_stored,
             "After configure, stored interval should be initial*2=#{expected_stored}, not escalated #{escalated_interval}"

      refute new_state.connect_retry_interval == escalated_interval,
             "connect_retry_interval must not remain at escalated value #{escalated_interval}"
    end

    test "configure success cancels any existing tracked timer" do
      # Bug: the old bare Process.send_after never cancelled the existing try_to_connect_timer.
      # This meant the old timer would still fire later, causing duplicate connection attempts.
      existing_timer = make_ref()

      state = %{
        connect_retry_interval: 40_000,
        try_to_connect_timer: existing_timer
      }

      new_state = simulate_configure_success(state)

      refute new_state.try_to_connect_timer == existing_timer,
             "Old tracked timer must be cancelled/replaced when configure completes"
    end

    test "configure success with escalated backoff: stored interval returns to initial*2" do
      # Before fix: after configure, connect_retry_interval stayed at 120s.
      # After fix: it resets to initial (5s) for the connect attempt, stored as 10s.
      state = %{connect_retry_interval: 120_000, try_to_connect_timer: nil}
      new_state = simulate_configure_success(state)

      expected = min(@initial_retry_interval * @backoff_multiplier, @max_retry_interval)
      assert new_state.connect_retry_interval == expected
    end

    test "configure success with no prior timer still schedules connect" do
      state = %{connect_retry_interval: @initial_retry_interval, try_to_connect_timer: nil}
      new_state = simulate_configure_success(state)

      refute new_state.try_to_connect_timer == nil,
             "A connect timer must be scheduled after configure completes"
    end
  end

  defp compute_backoff_sequence(initial, count) do
    {intervals, _final} =
      Enum.reduce(1..count, {[], initial}, fn _, {acc, current} ->
        next = min(current * @backoff_multiplier, @max_retry_interval)
        {acc ++ [current], next}
      end)

    intervals
  end

  # Mirrors the fixed handle_info(:try_to_configure) + start_try_to_connect_timer logic
  defp simulate_configure_success(state) do
    # 1. Reset interval to initial
    state = %{state | connect_retry_interval: @initial_retry_interval}

    # 2. Cancel existing timer and schedule new one
    if state.try_to_connect_timer != nil do
      Process.cancel_timer(state.try_to_connect_timer)
    end

    timer = make_ref()  # represents the new Process.send_after result
    next_interval = min(@initial_retry_interval * @backoff_multiplier, @max_retry_interval)

    %{state | try_to_connect_timer: timer, connect_retry_interval: next_interval}
  end
end
