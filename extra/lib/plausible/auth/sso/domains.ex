defmodule Plausible.Auth.SSO.Domains do
  @moduledoc """
  API for SSO domains.
  """

  import Ecto.Query

  alias Plausible.Auth
  alias Plausible.Auth.SSO
  alias Plausible.Auth.SSO.Domain.Verification
  alias Plausible.Repo

  use Plausible.Auth.SSO.Domain.Status

  @spec add(SSO.Integration.t(), String.t()) ::
          {:ok, SSO.Domain.t()} | {:error, Ecto.Changeset.t()}
  def add(integration, domain) do
    changeset = SSO.Domain.create_changeset(integration, domain)

    Repo.insert_with_audit(changeset, "sso_domain_added", %{team_id: integration.team_id})
  end

  @spec start_verification(String.t()) :: SSO.Domain.t()
  def start_verification(domain) when is_binary(domain) do
    {:ok, result} =
      Repo.transaction(fn ->
        with {:ok, sso_domain} <- get(domain) do
          sso_domain =
            sso_domain
            |> SSO.Domain.unverified_changeset(Status.in_progress())
            |> Repo.update_with_audit!(
              "sso_domain_verification_started",
              %{team_id: sso_domain.sso_integration.team_id}
            )

          {:ok, _} = Verification.Worker.enqueue(domain)
          {:ok, sso_domain}
        end
      end)

    result
  end

  @spec cancel_verification(String.t()) :: :ok
  def cancel_verification(domain) when is_binary(domain) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        with {:ok, sso_domain} <- get(domain) do
          sso_domain
          |> SSO.Domain.unverified_changeset(Status.unverified())
          |> Repo.update_with_audit("sso_domain_verification_cancelled", %{
            team_id: sso_domain.sso_integration.team_id
          })
        end

        :ok = Verification.Worker.cancel(domain)
      end)

    :ok
  end

  @spec verify(SSO.Domain.t(), Keyword.t()) :: SSO.Domain.t()
  def verify(%SSO.Domain{} = sso_domain, opts \\ []) do
    skip_checks? = Keyword.get(opts, :skip_checks?, false)
    verification_opts = Keyword.get(opts, :verification_opts, [])
    now = Keyword.get(opts, :now, NaiveDateTime.utc_now(:second))

    if skip_checks? do
      mark_verified!(sso_domain, :dns_txt, now)
    else
      case SSO.Domain.Verification.run(
             sso_domain.domain,
             sso_domain.identifier,
             verification_opts
           ) do
        {:ok, step} ->
          mark_verified!(sso_domain, step, now)

        {:error, :unverified} ->
          sso_domain
          |> SSO.Domain.unverified_changeset(Status.in_progress(), now)
          |> Repo.update!()
      end
    end
  end

  @spec get(String.t()) :: {:ok, SSO.Domain.t()} | {:error, :not_found}
  def get(domain) when is_binary(domain) do
    result =
      from(
        d in SSO.Domain,
        inner_join: i in assoc(d, :sso_integration),
        inner_join: t in assoc(i, :team),
        where: d.domain == ^domain,
        preload: [sso_integration: {i, team: t}]
      )
      |> Repo.one()

    if result do
      {:ok, result}
    else
      {:error, :not_found}
    end
  end

  @spec lookup(String.t()) :: {:ok, SSO.Domain.t()} | {:error, :not_found}
  def lookup(domain_or_email) when is_binary(domain_or_email) do
    search = normalize_lookup(domain_or_email)

    result =
      from(
        d in SSO.Domain,
        inner_join: i in assoc(d, :sso_integration),
        inner_join: t in assoc(i, :team),
        where: d.domain == ^search,
        where: d.status == ^Status.verified(),
        preload: [sso_integration: {i, team: t}]
      )
      |> Repo.one()

    if result do
      {:ok, result}
    else
      {:error, :not_found}
    end
  end

  @spec remove(SSO.Domain.t(), Keyword.t()) ::
          :ok | {:error, :force_sso_enabled | :sso_users_present}
  def remove(sso_domain, opts \\ []) do
    sso_domain = Repo.preload(sso_domain, :sso_integration)
    force_deprovision? = Keyword.get(opts, :force_deprovision?, false)

    check = check_can_remove(sso_domain)

    case {check, force_deprovision?} do
      {:ok, _} ->
        {:ok, :ok} =
          Repo.transaction(fn ->
            Repo.delete_with_audit!(sso_domain, "sso_domain_removed", %{
              team_id: sso_domain.sso_integration.team_id
            })

            :ok = cancel_verification(sso_domain.domain)
          end)

        :ok

      {{:error, :sso_users_present}, true} ->
        {:ok, :ok} =
          Repo.transaction(fn ->
            domain_users = users_by_domain(sso_domain)
            Enum.each(domain_users, &SSO.deprovision_user!/1)

            Repo.delete_with_audit!(sso_domain, "sso_domain_removed", %{
              team_id: sso_domain.sso_integration.team_id
            })

            cancel_verification(sso_domain.domain)
          end)

        :ok

      {{:error, error}, _} ->
        {:error, error}
    end
  end

  @spec check_can_remove(SSO.Domain.t()) ::
          :ok | {:error, :force_sso_enabled | :sso_users_present}
  def check_can_remove(sso_domain) do
    sso_domain = Repo.preload(sso_domain, sso_integration: [:team, :sso_domains])
    team = sso_domain.sso_integration.team
    domain_users_count = sso_domain |> users_by_domain_query() |> Repo.aggregate(:count)

    integration_users_count =
      sso_domain.sso_integration |> users_by_integration_query() |> Repo.aggregate(:count)

    only_domain_with_users? =
      domain_users_count > 0 and integration_users_count == domain_users_count

    cond do
      team.policy.force_sso != :none and only_domain_with_users? ->
        {:error, :force_sso_enabled}

      domain_users_count > 0 ->
        {:error, :sso_users_present}

      true ->
        :ok
    end
  end

  @spec mark_verified!(SSO.Domain.t(), SSO.Domain.verification_method(), NaiveDateTime.t()) ::
          SSO.Domain.t()
  def mark_verified!(sso_domain, method, now \\ NaiveDateTime.utc_now(:second)) do
    sso_domain
    |> SSO.Domain.verified_changeset(method, now)
    |> Repo.update_with_audit!("sso_domain_verification_success", %{
      team_id: sso_domain.sso_integration.team_id
    })
  end

  @spec mark_verification_failure!(SSO.Domain.t()) :: SSO.Domain.t()
  def mark_verification_failure!(sso_domain) do
    sso_domain
    |> SSO.Domain.unverified_changeset(Status.unverified())
    |> Repo.update_with_audit!("sso_domain_verification_failure", %{
      team_id: sso_domain.sso_integration.team_id
    })
  end

  defp users_by_domain(sso_domain) do
    sso_domain
    |> users_by_domain_query()
    |> Repo.all()
  end

  defp users_by_domain_query(sso_domain) do
    from(
      u in Auth.User,
      where: u.sso_domain_id == ^sso_domain.id
    )
  end

  defp users_by_integration_query(sso_integration) do
    from(
      u in Auth.User,
      where: u.sso_integration_id == ^sso_integration.id,
      where: u.type == :sso
    )
  end

  defp normalize_lookup(domain_or_email) do
    domain_or_email
    |> String.split("@", parts: 2)
    |> List.last()
    |> String.trim()
    |> String.downcase()
  end
end
