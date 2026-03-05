defmodule Symphony do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Symphony.Orchestrator.start_link(opts)
  end
end

defmodule Symphony.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Symphony.LogFile.configure()

    children = [
      {Task.Supervisor, name: Symphony.TaskSupervisor},
      Symphony.WorkflowStore,
      Symphony.Orchestrator,
      Symphony.HttpServer,
      Symphony.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Symphony.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    Symphony.StatusDashboard.render_offline_status()
    :ok
  end
end
