defmodule IncidentResponder.KnowledgeBase do
  @moduledoc """
  Service catalog, runbooks, on-call schedule, and severity definitions
  for a fictional microservices platform. Injected into system prompts.
  """

  @org "acme-platform"

  def org_name, do: @org

  def services do
    [
      %{
        name: "api-gateway",
        owner: "platform-team",
        language: "Go",
        health_endpoint: "https://api.acme.internal/healthz",
        port: 8080,
        dependencies: ["user-service", "payment-service"],
        description: "Public-facing API gateway. Routes all external traffic."
      },
      %{
        name: "user-service",
        owner: "identity-team",
        language: "Elixir",
        health_endpoint: "https://users.acme.internal/health",
        port: 4000,
        dependencies: ["postgres-primary", "redis-sessions"],
        description: "Authentication, profiles, and session management."
      },
      %{
        name: "payment-service",
        owner: "payments-team",
        language: "Java",
        health_endpoint: "https://payments.acme.internal/actuator/health",
        port: 8443,
        dependencies: ["postgres-payments", "stripe-api", "user-service"],
        description: "Processes charges, refunds, and payouts via Stripe."
      },
      %{
        name: "notification-service",
        owner: "comms-team",
        language: "Python",
        health_endpoint: "https://notify.acme.internal/ping",
        port: 5000,
        dependencies: ["redis-queue", "sendgrid-api", "user-service"],
        description: "Email, SMS, and push notifications. Async via Redis queue."
      }
    ]
  end

  def runbooks do
    %{
      "api-gateway" => [
        "1. Check health endpoint: curl https://api.acme.internal/healthz",
        "2. If 5xx spike: check upstream dependency health (user-service, payment-service)",
        "3. If latency spike: check connection pool saturation in Grafana",
        "4. Restart: kubectl rollout restart deployment/api-gateway -n production",
        "5. Rollback: kubectl rollout undo deployment/api-gateway -n production"
      ],
      "user-service" => [
        "1. Check health: curl https://users.acme.internal/health",
        "2. If auth failures: check Redis session store connectivity",
        "3. If DB errors: check postgres-primary replication lag in Grafana",
        "4. Restart: kubectl rollout restart deployment/user-service -n production",
        "5. Scale up: kubectl scale deployment/user-service --replicas=6 -n production"
      ],
      "payment-service" => [
        "1. Check health: curl https://payments.acme.internal/actuator/health",
        "2. If Stripe errors: check https://status.stripe.com for outages",
        "3. If transaction failures: check postgres-payments connection pool",
        "4. CRITICAL: Do NOT restart during active transactions — drain first",
        "5. Rollback: kubectl rollout undo deployment/payment-service -n production"
      ],
      "notification-service" => [
        "1. Check health: curl https://notify.acme.internal/ping",
        "2. If queue backlog: check Redis queue depth (notify:pending key)",
        "3. If email failures: check SendGrid status at status.sendgrid.com",
        "4. Scale workers: kubectl scale deployment/notify-workers --replicas=8 -n production",
        "5. Restart: kubectl rollout restart deployment/notification-service -n production"
      ]
    }
  end

  def oncall_schedule do
    [
      %{name: "Sarah Kim", handle: "@sarah-k", role: "Primary on-call", phone: "+1-555-0101", slack: "#incidents"},
      %{name: "Marcus Chen", handle: "@marcus-c", role: "Secondary on-call", phone: "+1-555-0102", slack: "#incidents"},
      %{name: "Priya Patel", handle: "@priya-p", role: "Incident commander", phone: "+1-555-0103", slack: "#incident-command"}
    ]
  end

  def severity_levels do
    [
      %{level: "SEV1", name: "Critical", response_time: "5 minutes", description: "Complete service outage or data loss. All hands on deck.", examples: "Payment processing down, data breach, full API outage"},
      %{level: "SEV2", name: "Major", response_time: "15 minutes", description: "Significant degradation affecting many users.", examples: "High error rates (>5%), major feature broken, auth failures"},
      %{level: "SEV3", name: "Minor", response_time: "1 hour", description: "Partial degradation with workaround available.", examples: "Slow responses, intermittent errors, one region affected"},
      %{level: "SEV4", name: "Low", response_time: "Next business day", description: "Minor issue with minimal user impact.", examples: "Cosmetic bugs, non-critical alerts, monitoring gaps"}
    ]
  end

  def services_text do
    services()
    |> Enum.map_join("\n\n", fn s ->
      deps = Enum.join(s.dependencies, ", ")

      "- **#{s.name}** (#{s.language}, port #{s.port})\n" <>
        "  Owner: #{s.owner} | Health: #{s.health_endpoint}\n" <>
        "  Dependencies: #{deps}\n" <>
        "  #{s.description}"
    end)
  end

  def runbooks_text do
    runbooks()
    |> Enum.map_join("\n\n", fn {service, steps} ->
      "### #{service}\n" <> Enum.join(steps, "\n")
    end)
  end

  def oncall_text do
    oncall_schedule()
    |> Enum.map_join("\n", fn p ->
      "- #{p.name} (#{p.handle}) — #{p.role} | #{p.phone} | Slack: #{p.slack}"
    end)
  end

  def severity_text do
    severity_levels()
    |> Enum.map_join("\n", fn s ->
      "- **#{s.level}** (#{s.name}) — Response: #{s.response_time}\n" <>
        "  #{s.description}\n" <>
        "  Examples: #{s.examples}"
    end)
  end

  def contact_text do
    "Slack: #incidents | Incident commander: @priya-p | Status page: https://status.acme.com"
  end
end
