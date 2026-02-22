import Config

if api_key = System.get_env("OPENROUTER_API_KEY") do
  config :lang_ex, :openai,
    api_key: api_key
end
