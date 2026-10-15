defmodule Agenda.GuidesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Every `elixir` block in the README and every guide, executed, and
  every result they claim, checked, and the cells of the livebook
  written for this version.

  The guides are prose with worked examples, and nothing else runs
  them — they are not doctests, so a broken one fails silently until a
  reader pastes it. Three missing variable bindings survived in them
  until this test existed, and two more in the README until it was
  covered here too.

  A block's `#=> value` comments are claims about what the expression
  above them returns, and a claim nobody checks drifts: the code keeps
  working while the printed answer goes stale. Each is compared
  against `inspect/1` of the value the guide's own code produced,
  ignoring whitespace so a result may be wrapped across lines. A claim
  containing `...` is an abbreviation rather than a value, and is
  read as illustration.

  Blocks within a guide share bindings, imports and aliases, in the
  order they appear, the way a reader working through the page (or
  Livebook, through a notebook) would. A block preceded by
  `<!-- guide-test: skip -->` is excluded, and the marker takes an
  optional reason — `<!-- guide-test: skip (why) -->`. It is an HTML
  comment, so it does not render.
  """

  # Sigils and predicates are in scope throughout a guide's prose even
  # where an individual block does not import them, so every block is
  # evaluated with both. Re-importing is harmless.
  @preamble "import Tempo.Sigils\nimport Agenda.Predicate\n"

  @block ~r/(?<skip><!-- guide-test: skip[^>]*-->\n)?```elixir\n(?<code>.*?)```/s

  @claim ~r/^\s*#=>\s?(?<text>.*)$/

  # The livebooks written against this version of Agenda run here too.
  # The Elixir Melbourne talk installs the release it was given with, and
  # is left as its record.
  documents =
    ["README.md" | Path.wildcard("guides/*.md")] ++ ["livebook/timesheets_and_leave.livemd"]

  # A wildcard that matches nothing would make this file pass by
  # testing zero guides, which is the failure mode it exists to catch.
  if documents == ["README.md"] do
    raise "no guides found — expected guides/*.md relative to the project root"
  end

  for document <- documents do
    @document document

    test "#{Path.basename(document)} runs end to end, and says what it does" do
      @document
      |> runnable_blocks()
      |> Enum.with_index(1)
      |> Enum.reduce({[], __ENV__}, fn {code, index}, scope ->
        run_block(code, index, scope, @document)
      end)
    end
  end

  defp run_block(code, index, scope, document) do
    Enum.reduce(claims(code), scope, fn {chunk, claimed}, scope ->
      {result, scope} = evaluate(chunk, code, index, scope, document)
      if claimed, do: compare(result, claimed, chunk, index, document)
      scope
    end)
  end

  defp evaluate(chunk, code, index, {binding, env}, document) do
    quoted = Code.string_to_quoted!(@preamble <> chunk, file: document)
    {result, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
    {result, {binding, env}}
  rescue
    error ->
      flunk("""
      #{document}, runnable block #{index} raised #{inspect(error.__struct__)}:

      #{Exception.message(error)}

      The block was:

      #{code}
      If the block is not meant to run — a `mix.exs` fragment, an
      output-only illustration, or an excerpt referring to data the
      guide does not show — put `<!-- guide-test: skip -->` on the
      line before its opening fence.
      """)
  end

  # An abbreviated claim is illustration, not a value to hold the code
  # to: `[%Agenda.Arrangement{...}]` says what shape comes back
  # without pinning every field of it.
  defp compare(result, claimed, chunk, index, document) do
    actual = inspect(result, limit: :infinity, printable_limit: :infinity)

    cond do
      String.contains?(claimed, "...") ->
        :ok

      squashed(actual) == squashed(claimed) ->
        :ok

      true ->
        flunk("""
        #{document}, block #{index}: the result claimed is not the result produced.

          claimed  #{claimed}
          produced #{actual}

        The expression was:

        #{String.trim_trailing(chunk)}
        """)
    end
  end

  defp squashed(text), do: String.replace(text, ~r/\s+/, "")

  # A block reads as a sequence of expressions, some of which are
  # followed by a claim about what they returned. Each claim closes a
  # chunk, so the chunk's last expression is the one being claimed
  # about, and a trailing chunk with no claim still has to run for the
  # bindings it makes.
  defp claims(code) do
    code
    |> String.split("\n")
    |> Enum.reduce({[], [], nil}, fn line, {chunks, held, claiming} ->
      case Regex.named_captures(@claim, line) do
        %{"text" => text} when is_nil(claiming) ->
          {chunks, held, text}

        %{"text" => text} ->
          {chunks, held, claiming <> " " <> text}

        nil when is_nil(claiming) ->
          {chunks, held ++ [line], nil}

        nil ->
          {chunks ++ [{Enum.join(held, "\n"), claiming}], [line], nil}
      end
    end)
    |> closed()
  end

  defp closed({chunks, held, nil}) do
    if held |> Enum.join("") |> String.trim() == "",
      do: chunks,
      else: chunks ++ [{Enum.join(held, "\n"), nil}]
  end

  defp closed({chunks, held, claiming}), do: chunks ++ [{Enum.join(held, "\n"), claiming}]

  # A livebook's setup cell installs the packages this suite already has.
  defp runnable_blocks(path) do
    @block
    |> Regex.scan(File.read!(path), capture: :all_names)
    |> Enum.reject(fn [_code, skip] -> skip != "" end)
    |> Enum.map(fn [code, _skip] -> code end)
    |> Enum.reject(&String.starts_with?(&1, "Mix.install("))
  end
end
