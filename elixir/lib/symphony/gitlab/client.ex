defmodule Symphony.GitLab.Client do
  @moduledoc """
  GitLab REST client for polling and normalizing project issues.
  """

  require Logger
  alias Symphony.{Config, GitLab.Issue}

  @page_size 100
  @request_timeout_ms 30_000

  @type assignee_filter ::
          nil
          | %{type: :assignee_id, value: String.t()}
          | %{type: :assignee, value: String.t()}
          | %{type: :assigned_to_me}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, assignee_filter} <- assignee_filter() do
      fetch_issues_by_states(Config.gitlab_active_states(),
        include_blockers: true,
        assignee_filter: assignee_filter
      )
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    case state_names do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, assignee_filter} <- assignee_filter() do
          fetch_issues_by_states(state_names,
            include_blockers: false,
            assignee_filter: assignee_filter
          )
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_iids =
      issue_ids
      |> Enum.map(&normalize_issue_iid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if issue_iids == [] do
      {:ok, []}
    else
      with {:ok, assignee_filter} <- assignee_filter(),
           {:ok, pages} <- fetch_issue_pages_by_iids(issue_iids, assignee_filter),
           {:ok, normalized} <-
             normalize_issues_from_pages(pages,
               include_blockers: true,
               assignee_filter: assignee_filter
             ) do
        {:ok, dedupe_issues(normalized)}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_iid, body) when is_binary(issue_iid) and is_binary(body) do
    with {:ok, _token} <- require_gitlab_token(),
         {:ok, project_id} <- require_gitlab_project_id(),
         {:ok, _response} <-
           request(:post, project_issue_path(project_id, issue_iid) <> "/notes",
             form: [{"body", body}]
           ) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_iid, state_name)
      when is_binary(issue_iid) and is_binary(state_name) do
    with {:ok, _token} <- require_gitlab_token(),
         {:ok, project_id} <- require_gitlab_project_id(),
         {:ok, state_event} <- gitlab_state_event(state_name),
         {:ok, _response} <-
           request(:put, project_issue_path(project_id, issue_iid),
             form: [{"state_event", state_event}]
           ) do
      :ok
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), assignee_filter() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue_payload, assignee_filter \\ nil)
      when is_map(issue_payload) do
    parsed_assignee_filter =
      case assignee_filter do
        value when is_binary(value) ->
          case normalize_assignee_filter(value) do
            {:ok, filter} -> filter
            _ -> nil
          end

        %{} = filter ->
          filter

        _ ->
          nil
      end

    case normalize_issue(issue_payload, parsed_assignee_filter, include_blockers: false) do
      {:ok, issue} -> issue
      _ -> nil
    end
  end

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> List.flatten()
    |> dedupe_issues()
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    with {:ok, token} <- require_gitlab_token() do
      payload = %{"query" => query, "variables" => variables}

      headers = [
        {"private-token", token},
        {"content-type", "application/json"}
      ]

      request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

      case request_fun.(payload, headers) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("GitLab GraphQL request failed status=#{status} body=#{inspect(body)}")
          {:error, {:gitlab_api_status, status}}

        {:ok, %{status: status, body: body}} ->
          Logger.error("GitLab GraphQL request failed status=#{status} body=#{inspect(body)}")
          {:error, {:gitlab_api_status, status}}

        {:error, reason} ->
          Logger.error("GitLab GraphQL request failed: #{inspect(reason)}")
          {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  defp fetch_issues_by_states(state_names, opts) do
    include_blockers = Keyword.get(opts, :include_blockers, false)
    assignee_filter = Keyword.get(opts, :assignee_filter)

    with {:ok, _token} <- require_gitlab_token(),
         {:ok, project_id} <- require_gitlab_project_id() do
      requested_states =
        state_names
        |> Enum.map(&normalize_state/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      state_queries = state_queries_for_requested_states(requested_states)

      with {:ok, pages} <-
             fetch_issue_pages_for_states(project_id, state_queries, assignee_filter),
           {:ok, normalized} <-
             normalize_issues_from_pages(pages,
               include_blockers: include_blockers,
               assignee_filter: assignee_filter
             ) do
        {:ok, filter_issues_for_requested_states(normalized, requested_states)}
      end
    end
  end

  defp fetch_issue_pages_for_states(project_id, state_queries, assignee_filter) do
    Enum.reduce_while(state_queries, {:ok, []}, fn state_query, {:ok, acc} ->
      params =
        [{"state", state_query}] ++
          assignee_filter_query_params(assignee_filter)

      case paginate_get(project_issues_path(project_id), params) do
        {:ok, pages} ->
          {:cont, {:ok, [pages | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, pages |> Enum.reverse() |> List.flatten()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_pages_by_iids(issue_iids, assignee_filter) do
    with {:ok, project_id} <- require_gitlab_project_id() do
      issue_iids
      |> Enum.chunk_every(@page_size)
      |> Enum.reduce_while({:ok, []}, fn issue_iid_chunk, {:ok, acc} ->
        params =
          Enum.map(issue_iid_chunk, &{"iids[]", &1}) ++
            [{"state", "all"}] ++
            assignee_filter_query_params(assignee_filter)

        case paginate_get(project_issues_path(project_id), params) do
          {:ok, pages} ->
            {:cont, {:ok, [pages | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, pages} -> {:ok, pages |> Enum.reverse() |> List.flatten()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_issues_from_pages(issue_payloads, opts) when is_list(issue_payloads) do
    include_blockers = Keyword.get(opts, :include_blockers, false)
    assignee_filter = Keyword.get(opts, :assignee_filter)

    issue_payloads
    |> Enum.reduce_while({:ok, []}, fn issue_payload, {:ok, acc} ->
      case normalize_issue(issue_payload, assignee_filter, include_blockers: include_blockers) do
        {:ok, issue} ->
          {:cont, {:ok, [issue | acc]}}

        :skip ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, issues |> Enum.reverse() |> dedupe_issues()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_issue(issue_payload, assignee_filter, opts)
       when is_map(issue_payload) and is_list(opts) do
    include_blockers = Keyword.get(opts, :include_blockers, false)

    issue_iid = normalize_issue_iid(issue_payload["iid"] || issue_payload["id"])
    embedded_blockers = extract_embedded_blockers(issue_payload)

    if is_nil(issue_iid) do
      :skip
    else
      assigned_to_worker = issue_routed_to_worker?(issue_payload, assignee_filter)

      with {:ok, blockers} <- maybe_fetch_blockers(issue_iid, include_blockers, embedded_blockers) do
        {:ok,
         %Issue{
           id: issue_iid,
           identifier: issue_identifier(issue_payload, issue_iid),
           title: normalize_text(issue_payload["title"]),
           description: normalize_nullable_text(issue_payload["description"]),
           priority: normalize_priority(issue_payload),
           state: normalize_issue_state_value(issue_payload["state"]),
           branch_name: nil,
           url: normalize_nullable_text(issue_payload["web_url"]),
           assignee_id: primary_assignee_id(issue_payload),
           blocked_by: blockers,
           labels: extract_labels(issue_payload),
           assigned_to_worker: assigned_to_worker,
           created_at: parse_datetime(issue_payload["created_at"]),
           updated_at: parse_datetime(issue_payload["updated_at"])
         }}
      end
    end
  end

  defp normalize_issue(_issue_payload, _assignee_filter, _opts), do: :skip

  defp normalize_priority(issue_payload) when is_map(issue_payload) do
    case issue_payload["priority"] do
      priority when is_integer(priority) and priority > 0 ->
        priority

      _ ->
        case issue_payload["weight"] do
          priority when is_integer(priority) and priority > 0 -> priority
          _ -> nil
        end
    end
  end

  defp normalize_priority(_issue_payload), do: nil

  defp normalize_issue_state_value(%{"name" => state_name}) when is_binary(state_name),
    do: normalize_text(state_name)

  defp normalize_issue_state_value(state_name), do: normalize_text(state_name)

  defp normalize_issue_iid(issue_iid) when is_integer(issue_iid), do: Integer.to_string(issue_iid)

  defp normalize_issue_iid(issue_iid) when is_binary(issue_iid) do
    case String.trim(issue_iid) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_issue_iid(_issue_iid), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_text(_value), do: nil

  defp normalize_nullable_text(value), do: normalize_text(value)

  defp extract_labels(issue_payload) when is_map(issue_payload) do
    labels_payload = Map.get(issue_payload, "labels", [])

    labels =
      case labels_payload do
        labels when is_list(labels) ->
          labels

        %{"nodes" => labels} when is_list(labels) ->
          labels

        _ ->
          []
      end

    labels
    |> Enum.map(fn
      %{"name" => label_name} -> label_name
      label_name -> label_name
    end)
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_issue_payload), do: []

  defp issue_identifier(issue_payload, issue_iid) when is_map(issue_payload) do
    references = issue_payload["references"]

    cond do
      is_map(references) and is_binary(references["full"]) and
          String.trim(references["full"]) != "" ->
        String.trim(references["full"])

      is_binary(issue_payload["web_url"]) and String.trim(issue_payload["web_url"]) != "" ->
        "##{issue_iid}"

      true ->
        "##{issue_iid}"
    end
  end

  defp primary_assignee_id(issue_payload) when is_map(issue_payload) do
    assignees = issue_assignees(issue_payload)

    case assignees do
      [%{"id" => assignee_id} | _] when is_integer(assignee_id) -> Integer.to_string(assignee_id)
      [%{"id" => assignee_id} | _] when is_binary(assignee_id) -> normalize_text(assignee_id)
      _ -> nil
    end
  end

  defp primary_assignee_id(_issue_payload), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp state_queries_for_requested_states(states) when is_list(states) do
    cond do
      states == [] -> ["opened"]
      states == ["opened"] -> ["opened"]
      states == ["closed"] -> ["closed"]
      Enum.all?(states, &(&1 in ["opened", "closed"])) -> Enum.uniq(states)
      true -> ["all"]
    end
  end

  defp filter_issues_for_requested_states(issues, []), do: issues

  defp filter_issues_for_requested_states(issues, requested_states) do
    state_set = MapSet.new(requested_states)

    Enum.filter(issues, fn
      %Issue{state: state} when is_binary(state) ->
        MapSet.member?(state_set, normalize_state(state))

      _ ->
        false
    end)
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp assignee_filter() do
    case Config.gitlab_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        normalize_assignee_filter(assignee)
    end
  end

  defp normalize_assignee_filter(assignee) when is_binary(assignee) do
    normalized = String.trim(assignee)

    cond do
      normalized == "" ->
        {:ok, nil}

      String.downcase(normalized) == "me" ->
        {:ok, %{type: :assigned_to_me, value: "me"}}

      String.match?(normalized, ~r/^\d+$/) ->
        {:ok, %{type: :assignee_id, value: normalized}}

      true ->
        {:ok, %{type: :assignee, value: normalized}}
    end
  end

  defp normalize_assignee_filter(_assignee), do: {:ok, nil}

  defp assignee_filter_query_params(nil), do: []

  defp assignee_filter_query_params(%{type: :assigned_to_me}) do
    [{"scope", "assigned_to_me"}]
  end

  defp assignee_filter_query_params(%{type: :assignee_id, value: value}) do
    [{"assignee_id", value}]
  end

  defp assignee_filter_query_params(%{type: :assignee}), do: []

  defp assignee_filter_query_params(_), do: []

  defp issue_routed_to_worker?(_issue_payload, nil), do: true

  defp issue_routed_to_worker?(issue_payload, %{type: :assigned_to_me}),
    do: has_any_assignee?(issue_payload)

  defp issue_routed_to_worker?(issue_payload, %{type: :assignee_id, value: value}) do
    issue_payload
    |> issue_assignees()
    |> Enum.any?(fn assignee ->
      assignee_id = assignee["id"]

      cond do
        is_integer(assignee_id) -> Integer.to_string(assignee_id) == value
        is_binary(assignee_id) -> String.trim(assignee_id) == value
        true -> false
      end
    end)
  end

  defp issue_routed_to_worker?(issue_payload, %{type: :assignee, value: value}) do
    normalized_value = String.downcase(String.trim(value))

    issue_payload
    |> issue_assignees()
    |> Enum.any?(fn assignee ->
      assignee_id = assignee["id"]
      username = assignee["username"]

      id_matches? =
        cond do
          is_integer(assignee_id) -> Integer.to_string(assignee_id) == value
          is_binary(assignee_id) -> String.trim(assignee_id) == value
          true -> false
        end

      username_matches? =
        if is_binary(username) do
          String.downcase(String.trim(username)) == normalized_value
        else
          false
        end

      id_matches? or username_matches?
    end)
  end

  defp issue_routed_to_worker?(_issue_payload, _assignee_filter), do: true

  defp has_any_assignee?(issue_payload) do
    case issue_assignees(issue_payload) do
      [] -> false
      _ -> true
    end
  end

  defp issue_assignees(issue_payload) when is_map(issue_payload) do
    case Map.get(issue_payload, "assignees") do
      assignees when is_list(assignees) ->
        assignees

      _ ->
        case Map.get(issue_payload, "assignee") do
          %{} = assignee -> [assignee]
          _ -> []
        end
    end
  end

  defp issue_assignees(_issue_payload), do: []

  defp maybe_fetch_blockers(_issue_iid, false, embedded_blockers), do: {:ok, embedded_blockers}

  defp maybe_fetch_blockers(issue_iid, true, embedded_blockers) do
    with {:ok, project_id} <- require_gitlab_project_id(),
         {:ok, link_pages} <-
           paginate_get(project_issue_path(project_id, issue_iid) <> "/links", []),
         {:ok, blockers} <- blockers_from_link_payloads(link_pages) do
      {:ok, merge_blockers(embedded_blockers, blockers)}
    end
  end

  defp blockers_from_link_payloads(link_payloads) when is_list(link_payloads) do
    blockers =
      link_payloads
      |> Enum.flat_map(fn
        %{"link_type" => link_type} = link when is_binary(link_type) ->
          if normalize_state(link_type) == "is_blocked_by" do
            [normalize_blocker(link)]
          else
            []
          end

        _ ->
          []
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, blockers}
  end

  defp blockers_from_link_payloads(_link_payloads), do: {:ok, []}

  defp merge_blockers(first, second) when is_list(first) and is_list(second) do
    (first ++ second)
    |> Enum.reduce({[], MapSet.new()}, fn blocker, {acc, seen_ids} ->
      blocker_id =
        case blocker do
          %{id: id} when is_binary(id) -> id
          _ -> nil
        end

      if is_nil(blocker_id) or MapSet.member?(seen_ids, blocker_id) do
        {acc, seen_ids}
      else
        {[blocker | acc], MapSet.put(seen_ids, blocker_id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp merge_blockers(first, _second) when is_list(first), do: first
  defp merge_blockers(_first, second) when is_list(second), do: second
  defp merge_blockers(_first, _second), do: []

  defp normalize_blocker(link_payload) when is_map(link_payload) do
    blocker_iid = normalize_issue_iid(link_payload["iid"])

    if is_nil(blocker_iid) do
      nil
    else
      %{
        id: blocker_iid,
        identifier: blocker_identifier(link_payload, blocker_iid),
        state: normalize_text(link_payload["state"])
      }
    end
  end

  defp normalize_blocker(_link_payload), do: nil

  defp extract_embedded_blockers(issue_payload) when is_map(issue_payload) do
    issue_payload
    |> Map.get("inverseRelations")
    |> case do
      %{"nodes" => relations} when is_list(relations) ->
        relations
        |> Enum.flat_map(fn
          %{"type" => relation_type, "issue" => blocker_issue}
          when is_binary(relation_type) and is_map(blocker_issue) ->
            if normalize_state(relation_type) == "blocks" do
              blocker_iid = normalize_issue_iid(blocker_issue["iid"] || blocker_issue["id"])

              if is_nil(blocker_iid) do
                []
              else
                [
                  %{
                    id: blocker_iid,
                    identifier: normalize_text(blocker_issue["identifier"]) || "##{blocker_iid}",
                    state: normalize_issue_state_value(blocker_issue["state"])
                  }
                ]
              end
            else
              []
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp extract_embedded_blockers(_issue_payload), do: []

  defp blocker_identifier(link_payload, blocker_iid) do
    references = Map.get(link_payload, "references")

    cond do
      is_map(references) and is_binary(references["full"]) and
          String.trim(references["full"]) != "" ->
        String.trim(references["full"])

      true ->
        "##{blocker_iid}"
    end
  end

  defp gitlab_state_event(state_name) when is_binary(state_name) do
    case normalize_state(state_name) do
      "closed" -> {:ok, "close"}
      "opened" -> {:ok, "reopen"}
      normalized -> {:error, {:unsupported_gitlab_state, normalized}}
    end
  end

  defp gitlab_state_event(_state_name), do: {:error, :invalid_gitlab_state}

  defp dedupe_issues(issues) when is_list(issues) do
    {deduped, _seen_ids} =
      Enum.reduce(issues, {[], MapSet.new()}, fn
        %Issue{id: id} = issue, {acc, seen_ids} when is_binary(id) ->
          if MapSet.member?(seen_ids, id) do
            {acc, seen_ids}
          else
            {[issue | acc], MapSet.put(seen_ids, id)}
          end

        _issue, accumulator ->
          accumulator
      end)

    Enum.reverse(deduped)
  end

  defp paginate_get(path, base_params) when is_binary(path) and is_list(base_params) do
    paginate_get(path, base_params, 1, [])
  end

  defp paginate_get(path, base_params, page, acc)
       when is_binary(path) and is_list(base_params) and is_integer(page) and is_list(acc) do
    params =
      base_params ++
        [{"per_page", Integer.to_string(@page_size)}, {"page", Integer.to_string(page)}]

    case request(:get, path, params: params) do
      {:ok, %Req.Response{body: body} = response} when is_list(body) ->
        next_page = response_header(response, "x-next-page")
        updated_acc = Enum.reverse(body, acc)

        if next_page == nil do
          {:ok, Enum.reverse(updated_acc)}
        else
          paginate_get(path, base_params, next_page, updated_acc)
        end

      {:ok, %Req.Response{body: body}} ->
        {:error, {:gitlab_unexpected_payload, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp response_header(%Req.Response{headers: headers}, key) when is_list(headers) do
    normalized_key = String.downcase(key)

    headers
    |> Enum.find_value(fn
      {header_key, header_value} when is_binary(header_key) and is_binary(header_value) ->
        if String.downcase(header_key) == normalized_key do
          header_value
        else
          nil
        end

      _ ->
        nil
    end)
    |> case do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> nil
        end
    end
  end

  defp response_header(_response, _key), do: nil

  defp request(method, path, opts) when is_atom(method) and is_binary(path) and is_list(opts) do
    request_fun = Application.get_env(:symphony, :gitlab_request_fun)

    cond do
      is_function(request_fun, 3) ->
        request_fun.(method, path, opts)

      true ->
        do_request(method, path, opts)
    end
  end

  defp do_request(method, path, opts) do
    with {:ok, token} <- require_gitlab_token() do
      headers = [
        {"private-token", token},
        {"content-type", "application/json"}
      ]

      req_opts = [
        method: method,
        url: gitlab_url(path),
        headers: headers,
        connect_options: [timeout: @request_timeout_ms],
        receive_timeout: @request_timeout_ms
      ]

      req_opts =
        req_opts
        |> maybe_put_params(Keyword.get(opts, :params))
        |> maybe_put_form(Keyword.get(opts, :form))

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning(
            "GitLab API request failed method=#{method} path=#{path} status=#{status} body=#{inspect(body)}"
          )

          {:error, {:gitlab_api_status, status}}

        {:error, reason} ->
          Logger.warning(
            "GitLab API request failed method=#{method} path=#{path} reason=#{inspect(reason)}"
          )

          {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  defp maybe_put_params(req_opts, params) when is_list(params),
    do: Keyword.put(req_opts, :params, params)

  defp maybe_put_params(req_opts, _params), do: req_opts

  defp maybe_put_form(req_opts, form) when is_list(form), do: Keyword.put(req_opts, :form, form)
  defp maybe_put_form(req_opts, _form), do: req_opts

  defp gitlab_url(path) do
    Config.gitlab_endpoint() <> path
  end

  defp gitlab_graphql_url do
    endpoint = Config.gitlab_endpoint()

    base_url =
      endpoint
      |> String.replace(~r{/api/v4/?$}, "")
      |> String.trim_trailing("/")

    base_url <> "/api/graphql"
  end

  defp post_graphql_request(payload, headers) do
    Req.post(gitlab_graphql_url(),
      headers: headers,
      json: payload,
      connect_options: [timeout: @request_timeout_ms],
      receive_timeout: @request_timeout_ms
    )
  end

  defp project_issues_path(project_id) when is_binary(project_id) do
    "/projects/#{URI.encode_www_form(project_id)}/issues"
  end

  defp project_issue_path(project_id, issue_iid)
       when is_binary(project_id) and is_binary(issue_iid) do
    "/projects/#{URI.encode_www_form(project_id)}/issues/#{URI.encode_www_form(issue_iid)}"
  end

  defp require_gitlab_token do
    case Config.gitlab_api_token() do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_gitlab_api_token}
    end
  end

  defp require_gitlab_project_id do
    case Config.gitlab_project_id() do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _ -> {:error, :missing_gitlab_project_id}
    end
  end
end
