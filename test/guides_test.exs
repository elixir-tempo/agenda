defmodule Agenda.GuidesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Every `elixir` block in every guide, executed.

  The guides are prose with worked examples, and nothing else runs
  them — they are not doctests, so a broken one fails silently until a
  reader pastes it. Three missing variable bindings survived in them
  until this test existed.

  Blocks within a guide share bindings, in the order they appear, the
  way a reader working through the page would. A block preceded by
  `<!-- guide-test: skip -->` is excluded, and the marker takes an
  optional reason — `<!-- guide-test: skip (why) -->`. It is an HTML
  comment, so it does not render.
  """

  # Sigils and predicates are in scope throughout a guide's prose even
  # where an individual block does not import them, so every block is
  # evaluated with both. Re-importing is harmless.
  @preamble "import Tempo.Sigils\nimport Agenda.Predicate\n"

  @block ~r/(?<skip><!-- guide-test: skip[^>]*-->\n)?```elixir\n(?<code>.*?)```/s

  guides = Path.wildcard("guides/*.md")

  # A wildcard that matches nothing would make this file pass by
  # testing zero guides, which is the failure mode it exists to catch.
  if guides == [] do
    raise "no guides found — expected guides/*.md relative to the project root"
  end

  for guide <- guides do
    @guide guide

    test "#{Path.basename(guide)} runs end to end" do
      @guide
      |> runnable_blocks()
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {code, index}, binding ->
        try do
          {_result, binding} = Code.eval_string(@preamble <> code, binding)
          binding
        rescue
          error ->
            flunk("""
            #{@guide}, runnable block #{index} raised #{inspect(error.__struct__)}:

            #{Exception.message(error)}

            The block was:

            #{code}
            If the block is not meant to run — a `mix.exs` fragment, an
            output-only illustration, or an excerpt referring to data the
            guide does not show — put `<!-- guide-test: skip -->` on the
            line before its opening fence.
            """)
        end
      end)
    end
  end

  defp runnable_blocks(path) do
    @block
    |> Regex.scan(File.read!(path), capture: :all_names)
    |> Enum.reject(fn [_code, skip] -> skip != "" end)
    |> Enum.map(fn [code, _skip] -> code end)
  end
end
