import Config

if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :lang_ex, :anthropic,
    api_key: api_key
end
