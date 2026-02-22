defmodule IncidentResponder.Tools do
  @moduledoc """
  Stubbed DevOps tools using the `%LangEx.Tool{function: ...}` pattern.

  Each tool logs its invocation and returns realistic fake data.
  Passed directly to `LangEx.ToolNode.node/2`.
  """

  def tool_declarations do
    [
      check_service_health_tool(),
      get_recent_logs_tool(),
      get_metrics_tool(),
      restart_service_tool(),
      page_oncall_tool(),
      update_status_page_tool()
    ]
  end

  defp check_service_health_tool do
    %LangEx.Tool{
      name: "check_service_health",
      description: "Check the health status of a service. Returns status, latency, and error rate.",
      parameters: %{
        type: "object",
        properties: %{
          service: %{type: "string", description: "Service name (e.g. api-gateway, user-service)"}
        },
        required: ["service"]
      },
      function: fn %{"service" => service} ->
        IO.puts("\n  [TOOL] check_service_health(#{service})\n")
        fake_health(service)
      end
    }
  end

  defp get_recent_logs_tool do
    %LangEx.Tool{
      name: "get_recent_logs",
      description: "Fetch recent log entries for a service. Returns last 5 entries with timestamps and levels.",
      parameters: %{
        type: "object",
        properties: %{
          service: %{type: "string", description: "Service name"},
          level: %{type: "string", enum: ["error", "warn", "info", "all"], description: "Log level filter"}
        },
        required: ["service"]
      },
      function: fn %{"service" => service} = args ->
        level = args["level"] || "all"
        IO.puts("\n  [TOOL] get_recent_logs(#{service}, level: #{level})\n")
        fake_logs(service, level)
      end
    }
  end

  defp get_metrics_tool do
    %LangEx.Tool{
      name: "get_metrics",
      description: "Get current performance metrics for a service: CPU, memory, request rate, p99 latency.",
      parameters: %{
        type: "object",
        properties: %{
          service: %{type: "string", description: "Service name"},
          window: %{type: "string", enum: ["5m", "15m", "1h"], description: "Time window for metrics"}
        },
        required: ["service"]
      },
      function: fn %{"service" => service} = args ->
        window = args["window"] || "5m"
        IO.puts("\n  [TOOL] get_metrics(#{service}, window: #{window})\n")
        fake_metrics(service, window)
      end
    }
  end

  defp restart_service_tool do
    %LangEx.Tool{
      name: "restart_service",
      description: "Restart a service by triggering a rolling deployment. Only call after confirming with the responder.",
      parameters: %{
        type: "object",
        properties: %{
          service: %{type: "string", description: "Service name"},
          reason: %{type: "string", description: "Reason for restart (for audit log)"}
        },
        required: ["service", "reason"]
      },
      function: fn %{"service" => service, "reason" => reason} ->
        IO.puts("\n  [TOOL] restart_service(#{service}, reason: #{reason})\n")

        %{
          success: true,
          service: service,
          action: "rolling_restart",
          new_pods: 3,
          old_pods_terminating: 3,
          estimated_completion: "90 seconds",
          message: "Rolling restart initiated for #{service}. 3 new pods spinning up, 3 old pods draining."
        }
      end
    }
  end

  defp page_oncall_tool do
    %LangEx.Tool{
      name: "page_oncall",
      description: "Page the on-call engineer via PagerDuty. Use for SEV1/SEV2 incidents.",
      parameters: %{
        type: "object",
        properties: %{
          severity: %{type: "string", enum: ["SEV1", "SEV2", "SEV3", "SEV4"], description: "Incident severity"},
          service: %{type: "string", description: "Affected service"},
          summary: %{type: "string", description: "Brief incident summary"}
        },
        required: ["severity", "service", "summary"]
      },
      function: fn %{"severity" => severity, "service" => service, "summary" => summary} ->
        IO.puts("\n  [TOOL] page_oncall(#{severity}, #{service}, #{summary})\n")

        %{
          success: true,
          paged: "Sarah Kim (@sarah-k)",
          method: "PagerDuty + Slack #incidents",
          severity: severity,
          incident_id: "INC-#{:rand.uniform(9999)}",
          message: "Paged Sarah Kim (primary on-call) via PagerDuty. Incident #{severity} created for #{service}: #{summary}"
        }
      end
    }
  end

  defp update_status_page_tool do
    %LangEx.Tool{
      name: "update_status_page",
      description: "Update the public status page (status.acme.com) with incident information.",
      parameters: %{
        type: "object",
        properties: %{
          service: %{type: "string", description: "Affected service"},
          status: %{type: "string", enum: ["investigating", "identified", "monitoring", "resolved"], description: "Incident status"},
          message: %{type: "string", description: "Public-facing status message"}
        },
        required: ["service", "status", "message"]
      },
      function: fn %{"service" => service, "status" => status, "message" => message} ->
        IO.puts("\n  [TOOL] update_status_page(#{service}, #{status})\n")

        %{
          success: true,
          url: "https://status.acme.com/incidents/#{:rand.uniform(999)}",
          service: service,
          status: status,
          message: "Status page updated: #{service} — #{status}. Public message: \"#{message}\""
        }
      end
    }
  end

  # --- Stubbed data ---

  defp fake_health("api-gateway") do
    %{
      service: "api-gateway",
      status: "degraded",
      http_status: 503,
      latency_ms: 2340,
      error_rate_percent: 12.4,
      uptime_percent: 94.2,
      healthy_pods: 1,
      total_pods: 3,
      message: "api-gateway is degraded. 2 of 3 pods unhealthy, error rate 12.4%, latency 2.3s."
    }
  end

  defp fake_health("user-service") do
    %{
      service: "user-service",
      status: "healthy",
      http_status: 200,
      latency_ms: 45,
      error_rate_percent: 0.1,
      uptime_percent: 99.98,
      healthy_pods: 4,
      total_pods: 4,
      message: "user-service is healthy. All 4 pods up, latency 45ms, error rate 0.1%."
    }
  end

  defp fake_health("payment-service") do
    %{
      service: "payment-service",
      status: "degraded",
      http_status: 200,
      latency_ms: 890,
      error_rate_percent: 3.7,
      uptime_percent: 97.1,
      healthy_pods: 2,
      total_pods: 3,
      message: "payment-service is degraded. 1 pod unhealthy, error rate 3.7%, latency elevated at 890ms."
    }
  end

  defp fake_health("notification-service") do
    %{
      service: "notification-service",
      status: "healthy",
      http_status: 200,
      latency_ms: 120,
      error_rate_percent: 0.3,
      uptime_percent: 99.9,
      healthy_pods: 2,
      total_pods: 2,
      message: "notification-service is healthy. Queue depth normal, latency 120ms."
    }
  end

  defp fake_health(other) do
    %{service: other, status: "unknown", message: "Service '#{other}' not found in service catalog."}
  end

  defp fake_logs("api-gateway", _level) do
    %{
      service: "api-gateway",
      entries: [
        %{timestamp: "2026-02-22T14:32:01Z", level: "error", message: "upstream connect error: connection refused to user-service:4000"},
        %{timestamp: "2026-02-22T14:31:58Z", level: "error", message: "503 Service Unavailable - POST /api/v1/orders"},
        %{timestamp: "2026-02-22T14:31:45Z", level: "warn", message: "circuit breaker OPEN for payment-service (5 consecutive failures)"},
        %{timestamp: "2026-02-22T14:31:30Z", level: "error", message: "timeout after 5000ms waiting for upstream response"},
        %{timestamp: "2026-02-22T14:31:12Z", level: "info", message: "health check passed for pod api-gateway-7b4d9f-x2k"}
      ]
    }
  end

  defp fake_logs("payment-service", _level) do
    %{
      service: "payment-service",
      entries: [
        %{timestamp: "2026-02-22T14:32:05Z", level: "error", message: "Stripe API timeout: POST /v1/charges (30s deadline exceeded)"},
        %{timestamp: "2026-02-22T14:31:50Z", level: "warn", message: "connection pool exhausted: postgres-payments (max: 20, waiting: 8)"},
        %{timestamp: "2026-02-22T14:31:40Z", level: "error", message: "transaction rollback: could not serialize access due to concurrent update"},
        %{timestamp: "2026-02-22T14:31:20Z", level: "info", message: "processed 142 transactions in last 60s"},
        %{timestamp: "2026-02-22T14:31:00Z", level: "warn", message: "retry attempt 3/5 for charge ch_3Nq2xR... (Stripe 429)"}
      ]
    }
  end

  defp fake_logs(service, _level) do
    %{
      service: service,
      entries: [
        %{timestamp: "2026-02-22T14:32:00Z", level: "info", message: "request processed successfully in 42ms"},
        %{timestamp: "2026-02-22T14:31:30Z", level: "info", message: "health check passed"},
        %{timestamp: "2026-02-22T14:31:00Z", level: "info", message: "periodic cleanup completed: 0 stale sessions removed"}
      ]
    }
  end

  defp fake_metrics("api-gateway", _window) do
    %{
      service: "api-gateway",
      window: "5m",
      cpu_percent: 78.3,
      memory_percent: 62.1,
      request_rate_per_sec: 1240,
      p50_latency_ms: 890,
      p99_latency_ms: 4200,
      error_count: 154,
      success_count: 1086
    }
  end

  defp fake_metrics("payment-service", _window) do
    %{
      service: "payment-service",
      window: "5m",
      cpu_percent: 45.2,
      memory_percent: 71.8,
      request_rate_per_sec: 89,
      p50_latency_ms: 340,
      p99_latency_ms: 2100,
      error_count: 33,
      success_count: 412
    }
  end

  defp fake_metrics(service, _window) do
    %{
      service: service,
      window: "5m",
      cpu_percent: 22.5,
      memory_percent: 38.0,
      request_rate_per_sec: 320,
      p50_latency_ms: 35,
      p99_latency_ms: 120,
      error_count: 2,
      success_count: 1598
    }
  end
end
