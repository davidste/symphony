defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @ensure_issue_started_tool "ensure_issue_started"
  @set_issue_state_tool "set_issue_state"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @ensure_issue_started_description """
  Fetch a compact Linear issue startup snapshot, find an existing unresolved workpad comment, and move the issue from Todo to a target state if needed.
  """
  @ensure_issue_started_query """
  query($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      url
      description
      state { id name type }
      team {
        states { nodes { id name type } }
      }
      comments(first: 50) {
        nodes { id body resolvedAt }
      }
    }
  }
  """
  @ensure_issue_started_update """
  mutation($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: { stateId: $stateId }) {
      success
      issue { id identifier state { id name type } }
    }
  }
  """
  @ensure_issue_started_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "target_state" => %{
        "type" => "string",
        "description" => "State name to ensure when the issue is currently Todo. Defaults to \"In Progress\"."
      },
      "workpad_marker" => %{
        "type" => "string",
        "description" => "Heading text used to detect an existing workpad comment. Defaults to \"## Codex Workpad\"."
      }
    }
  }

  @set_issue_state_description """
  Move a Linear issue to the named state by resolving the state ID through the issue's team configuration.
  """
  @set_issue_state_query """
  query($id: String!) {
    issue(id: $id) {
      id
      identifier
      state { id name type }
      team { states { nodes { id name type } } }
    }
  }
  """
  @set_issue_state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "state_name"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "state_name" => %{
        "type" => "string",
        "description" => "Target Linear state name, for example \"Done\" or \"In Progress\"."
      }
    }
  }

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description "Create or update a workpad comment on a Linear issue. Reads the body from a local file to keep the conversation context small."
  @sync_workpad_create "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id url } } }"
  @sync_workpad_update "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success comment { id url } } }"
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Path to a local markdown file whose contents become the comment body."
      },
      "comment_id" => %{
        "type" => "string",
        "description" => "Existing comment ID to update. Omit to create a new comment."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @ensure_issue_started_tool ->
        execute_ensure_issue_started(arguments, opts)

      @set_issue_state_tool ->
        execute_set_issue_state(arguments, opts)

      @sync_workpad_tool ->
        execute_sync_workpad(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @ensure_issue_started_tool,
        "description" => @ensure_issue_started_description,
        "inputSchema" => @ensure_issue_started_input_schema
      },
      %{
        "name" => @set_issue_state_tool,
        "description" => @set_issue_state_description,
        "inputSchema" => @set_issue_state_input_schema
      },
      %{
        "name" => @sync_workpad_tool,
        "description" => @sync_workpad_description,
        "inputSchema" => @sync_workpad_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_ensure_issue_started(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, issue_id, target_state, workpad_marker} <- normalize_ensure_issue_started_args(arguments),
         {:ok, response} <- linear_client.(@ensure_issue_started_query, %{"id" => issue_id}, []),
         {:ok, issue} <- extract_issue_snapshot(response),
         {:ok, issue, state_changed} <-
           maybe_move_issue(linear_client, issue, issue_id, target_state, @ensure_issue_started_update) do
      graphql_response(%{
        "data" => %{
          "issue" => issue_start_payload(issue, workpad_marker),
          "stateChanged" => state_changed
        }
      })
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_set_issue_state(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, issue_id, state_name} <- normalize_set_issue_state_args(arguments),
         {:ok, response} <- linear_client.(@set_issue_state_query, %{"id" => issue_id}, []),
         {:ok, issue} <- extract_issue_snapshot(response),
         {:ok, target_state_id} <- find_state_id(issue, state_name),
         {:ok, update_response} <-
           linear_client.(@ensure_issue_started_update, %{"id" => issue_id, "stateId" => target_state_id}, []),
         {:ok, updated_issue} <- extract_updated_issue(update_response) do
      graphql_response(%{"data" => %{"issue" => compact_issue_payload(updated_issue)}})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sync_workpad(args, opts) do
    with {:ok, issue_id, file_path, comment_id} <- normalize_sync_workpad_args(args),
         {:ok, body} <- read_workpad_file(file_path) do
      {query, variables} =
        if comment_id,
          do: {@sync_workpad_update, %{"id" => comment_id, "body" => body}},
          else: {@sync_workpad_create, %{"issueId" => issue_id, "body" => body}}

      execute_linear_graphql(%{"query" => query, "variables" => variables}, opts)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_sync_workpad_args(%{} = args) do
    with {:ok, issue_id} <- required_string_arg(args, "issue_id"),
         {:ok, file_path} <- required_string_arg(args, "file_path") do
      {:ok, issue_id, file_path, optional_string_arg(args, "comment_id")}
    end
  end

  defp normalize_sync_workpad_args(_args) do
    {:error, {:sync_workpad, "`issue_id` and `file_path` are required"}}
  end

  defp normalize_ensure_issue_started_args(%{} = args) do
    with {:ok, issue_id} <- required_string_arg(args, "issue_id") do
      {:ok, issue_id, optional_string_arg(args, "target_state") || "In Progress", optional_string_arg(args, "workpad_marker") || "## Codex Workpad"}
    end
  end

  defp normalize_ensure_issue_started_args(_args) do
    {:error, {:ensure_issue_started, "`issue_id` is required"}}
  end

  defp normalize_set_issue_state_args(%{} = args) do
    with {:ok, issue_id} <- required_string_arg(args, "issue_id"),
         {:ok, state_name} <- required_set_issue_state_arg(args, "state_name") do
      {:ok, issue_id, state_name}
    end
  end

  defp normalize_set_issue_state_args(_args) do
    {:error, {:set_issue_state, "`issue_id` and `state_name` are required"}}
  end

  defp required_set_issue_state_arg(args, key) when is_map(args) do
    case optional_string_arg(args, key) do
      nil -> {:error, {:set_issue_state, "`#{key}` is required"}}
      value -> {:ok, value}
    end
  end

  defp required_string_arg(args, key) when is_map(args) do
    case optional_string_arg(args, key) do
      nil -> {:error, {:sync_workpad, "`#{key}` is required"}}
      value -> {:ok, value}
    end
  end

  defp optional_string_arg(args, key) when is_map(args) and is_binary(key) do
    args
    |> Map.get(key)
    |> normalize_optional_string()
    |> case do
      nil -> args |> Map.get(String.to_atom(key)) |> normalize_optional_string()
      value -> value
    end
  end

  defp optional_string_arg(_args, _key), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp extract_issue_snapshot(%{"data" => %{"issue" => nil}}), do: {:error, {:linear_issue, "issue not found"}}
  defp extract_issue_snapshot(%{"data" => %{"issue" => issue}}) when is_map(issue), do: {:ok, issue}
  defp extract_issue_snapshot(_response), do: {:error, {:linear_issue, "issue payload missing from response"}}

  defp extract_updated_issue(%{"data" => %{"issueUpdate" => %{"issue" => issue, "success" => true}}})
       when is_map(issue),
       do: {:ok, issue}

  defp extract_updated_issue(%{"data" => %{"issueUpdate" => %{"success" => false}}}),
    do: {:error, {:linear_issue, "issue update failed"}}

  defp extract_updated_issue(_response),
    do: {:error, {:linear_issue, "updated issue payload missing from response"}}

  defp maybe_move_issue(linear_client, issue, issue_id, target_state, update_query) do
    current_state = get_in(issue, ["state", "name"])

    cond do
      current_state == target_state ->
        {:ok, issue, false}

      current_state == "Todo" ->
        with {:ok, target_state_id} <- find_state_id(issue, target_state),
             {:ok, response} <- linear_client.(update_query, %{"id" => issue_id, "stateId" => target_state_id}, []),
             {:ok, updated_issue} <- extract_updated_issue(response) do
          {:ok, Map.put(issue, "state", updated_issue["state"]), true}
        end

      true ->
        {:ok, issue, false}
    end
  end

  defp find_state_id(issue, state_name) do
    issue
    |> get_in(["team", "states", "nodes"])
    |> List.wrap()
    |> Enum.find_value(fn state ->
      if get_in(state, ["name"]) == state_name, do: get_in(state, ["id"]), else: nil
    end)
    |> case do
      nil -> {:error, {:linear_issue, "team does not contain state `#{state_name}`"}}
      state_id -> {:ok, state_id}
    end
  end

  defp issue_start_payload(issue, workpad_marker) do
    workpad_comment = find_workpad_comment(issue, workpad_marker)

    %{
      "id" => issue["id"],
      "identifier" => issue["identifier"],
      "title" => issue["title"],
      "url" => issue["url"],
      "description" => issue["description"],
      "state" => compact_state_payload(issue["state"]),
      "workpadCommentId" => workpad_comment && workpad_comment["id"],
      "workpadFound" => not is_nil(workpad_comment)
    }
  end

  defp compact_issue_payload(issue) do
    %{
      "id" => issue["id"],
      "identifier" => issue["identifier"],
      "state" => compact_state_payload(issue["state"])
    }
  end

  defp compact_state_payload(nil), do: nil

  defp compact_state_payload(state) do
    %{
      "id" => state["id"],
      "name" => state["name"],
      "type" => state["type"]
    }
  end

  defp find_workpad_comment(issue, workpad_marker) do
    issue
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.find(fn comment ->
      is_nil(comment["resolvedAt"]) and
        comment["body"]
        |> to_string()
        |> String.starts_with?(workpad_marker)
    end)
  end

  defp read_workpad_file(path) do
    case File.read(path) do
      {:ok, ""} -> {:error, {:sync_workpad, "file is empty: `#{path}`"}}
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:sync_workpad, "cannot read `#{path}`: #{:file.format_error(reason)}"}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload({:sync_workpad, message}) do
    %{"error" => %{"message" => "sync_workpad: #{message}"}}
  end

  defp tool_error_payload({:ensure_issue_started, message}) do
    %{"error" => %{"message" => "ensure_issue_started: #{message}"}}
  end

  defp tool_error_payload({:set_issue_state, message}) do
    %{"error" => %{"message" => "set_issue_state: #{message}"}}
  end

  defp tool_error_payload({:linear_issue, message}) do
    %{"error" => %{"message" => message}}
  end

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
