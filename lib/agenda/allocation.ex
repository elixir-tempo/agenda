defmodule Agenda.Allocation do
  @moduledoc """
  One resource, bound to one session, over one interval.

  An allocation is **keyed by the session that holds it**. That single
  decision is what makes releasing a resource a consequence rather than
  a workflow: cancelling a session drops its key, and every resource it
  held is free again because nothing else was holding them. There is no
  release step to forget.

  An allocation is the persisted grain of a
  `t:Agenda.Arrangement.t/0` — the arrangement proposes a room and a
  roster for a time, and allocating it records one of these per
  resource.

  ## The tag

  `tag` records **what the claim was for**, as a `{kind, subject}`
  pair. It is the field that lets one ledger hold work and absence in
  the same structure:

      {:project, "ACME-2026-01"}
      {:leave, :annual}
      {:holiday, "Brisbane show day"}

  Nothing here interprets a tag — `agenda` does not know what a project
  or a leave type is, and does not decide which kinds exist. What it
  gains is that a person's time can be reconciled without a second
  schema: every claim on a resource is in one place, and the tag says
  which bucket it belongs to. `Agenda.reconcile/3` groups by it.

  The consequence worth naming: a day cannot be two things. A
  consultant on annual leave cannot also be billed to a project,
  because both would be claims on the same resource over the same
  span, and that is the overlap the ledger already refuses.

  """

  alias Agenda.Arrangement

  @typedoc """
  One resource held by one session for one interval.

  `held_until` marks a **tentative** claim — a hold, not a booking. It
  occupies the resource exactly as a firm allocation does, which is why
  it lives here rather than in a persistence layer: availability is
  derived on every call, so a hold nobody can see is a hold nobody
  subtracts. `nil` means the claim is firm.

  `tag` records what the claim was for. `nil` means untagged, which is
  every allocation made before a caller asks for one.
  """
  @type t :: %__MODULE__{
          session: String.t(),
          role: atom(),
          resource: String.t(),
          interval: Tempo.Interval.t(),
          series: String.t() | nil,
          held_until: Tempo.t() | nil,
          tag: tag() | nil
        }

  @typedoc """
  What a claim was for, as `{kind, subject}`.

  The kinds are the caller's, not this library's. `{:project, "ACME"}`,
  `{:leave, :annual}` and `{:holiday, "Show day"}` are the three this
  library's documentation uses, because they are the three a timesheet
  needs, but nothing rejects another.
  """
  @type tag :: {atom(), term()}

  defstruct [:session, :role, :resource, :interval, :series, :held_until, :tag]

  @doc """
  The allocations an arrangement implies — one per resource, across
  every role.

  ### Arguments

  * `arrangement` is a `t:Agenda.Arrangement.t/0`.

  ### Options

  * `:tag` is what the claim was for, as a `t:tag/0` — `{:project,
    "ACME-2026-01"}` or `{:leave, :annual}`. Every allocation the
    arrangement implies carries it, because they are one booking. The
    default is `nil`.

  ### Returns

  * the allocations, ordered by role then resource name so that two
    equal arrangements always yield an equal list.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.resource("Boardroom")
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> [allocation] = Agenda.Allocation.from_arrangement(arrangement)
      iex> {allocation.session, allocation.role, allocation.resource}
      {"Review", :room, "Boardroom"}

  Tagging what the claim was for:

      iex> import Tempo.Sigils
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Discovery",
      ...>   interval: ~o"2026-06-16T09:00:00/2026-06-16T17:00:00",
      ...>   allocations: %{consultant: [Agenda.resource("Dana")]}
      ...> }
      iex> [allocation] =
      ...>   Agenda.Allocation.from_arrangement(arrangement, tag: {:project, "ACME-2026-01"})
      iex> allocation.tag
      {:project, "ACME-2026-01"}

  """
  @spec from_arrangement(Arrangement.t(), keyword()) :: [t()]
  def from_arrangement(%Arrangement{} = arrangement, options \\ []) do
    tag = Keyword.get(options, :tag)

    arrangement.allocations
    |> Enum.flat_map(fn {role, resources} ->
      Enum.map(resources, fn resource ->
        %__MODULE__{
          session: arrangement.session,
          role: role,
          resource: resource.name,
          interval: arrangement.interval,
          series: arrangement.series,
          tag: tag
        }
      end)
    end)
    |> Enum.sort_by(&{&1.role, &1.resource})
  end

  @doc """
  `true` when two allocations bind the same resource, in the same
  role, over the same span.

  This is the identity a changeset compares on — it deliberately
  ignores which session holds it, because `rearrange/3` asks "is this
  same binding still wanted?" within one session.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> import Tempo.Sigils
      iex> hour = ~o"2026-06-16T10:00:00/2026-06-16T11:00:00"
      iex> a = %Agenda.Allocation{role: :room, resource: "Boardroom", interval: hour}
      iex> b = %Agenda.Allocation{role: :room, resource: "Boardroom", interval: hour}
      iex> Agenda.Allocation.same?(a, b)
      true

  """
  @spec same?(t(), t()) :: boolean()
  def same?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.role == b.role and a.resource == b.resource and
      Tempo.equal?(a.interval, b.interval)
  end
end
