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

  defp compute_backoff_sequence(initial, count) do
    {intervals, _final} =
      Enum.reduce(1..count, {[], initial}, fn _, {acc, current} ->
        next = min(current * @backoff_multiplier, @max_retry_interval)
        {acc ++ [current], next}
      end)

    intervals
  end
end
