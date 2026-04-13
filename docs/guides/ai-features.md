# AI Features Guide

MysqlGenius integrates with OpenAI-compatible LLM APIs to provide AI-powered database analysis. All AI features are optional — the dashboard works fully without them.

## Supported providers

| Provider | Endpoint | Auth Style |
|---|---|---|
| OpenAI | `https://api.openai.com/v1/chat/completions` | Bearer |
| Anthropic | `https://api.anthropic.com/v1/messages` | x-api-key |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` | Bearer |
| Azure OpenAI | `https://YOUR-RESOURCE.openai.azure.com/...` | api-key |
| DeepSeek | `https://api.deepseek.com/chat/completions` | Bearer |
| Groq | `https://api.groq.com/openai/v1/chat/completions` | Bearer |
| Ollama (local) | `http://localhost:11434/v1/chat/completions` | Bearer |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | Bearer |
| Perplexity | `https://api.perplexity.ai/chat/completions` | Bearer |
| Any OpenAI-compatible | Your endpoint URL | Bearer or api-key |

## Configuration

In your Rails initializer (`config/initializers/mysql_genius.rb`):

```ruby
MysqlGenius.configure do |config|
  config.ai_endpoint = "https://api.openai.com/v1/chat/completions"
  config.ai_api_key = ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o-mini"
  config.ai_auth_style = :bearer  # or :api_key for Azure, :x_api_key for Anthropic
end
```

## Available features

### Query Explorer AI

| Feature | What it does | Where |
|---|---|---|
| **AI Suggest** | Generate SQL from natural language | Query Explorer tab |
| **AI Optimization** | Analyze EXPLAIN output, suggest improvements | After running EXPLAIN |
| **Index Advisor** | Recommend indexes for a specific query | After running EXPLAIN |
| **Describe Query** | Explain what a SQL query does in plain English | Query Explorer tab |
| **Rewrite Query** | Suggest an optimized version of the SQL | Query Explorer tab |

### Schema & Migration

| Feature | What it does | Where |
|---|---|---|
| **Schema Review** | Find anti-patterns across your schema | AI Tools tab |
| **Migration Risk** | Assess safety of a DDL/migration before deploying | AI Tools tab |
| **AI Optimize** | Review a specific table's schema (appears on fragmented tables) | Tables tab |

### Server Analysis

| Feature | What it does | Where |
|---|---|---|
| **Variable Config Review** | Review my.cnf settings against your workload | Server tab |
| **Connection Advisor** | Diagnose connection pool issues | Server tab |
| **InnoDB Health** | Interpret SHOW ENGINE INNODB STATUS | Server tab |

### Workload Analysis

| Feature | What it does | Where |
|---|---|---|
| **Workload Digest** | Executive summary of your query workload | Query Stats tab |
| **Pattern Grouper** | Group slow queries by shared root cause | Query Stats tab |
| **Index Planner** | Holistic index optimization plan | Indexes tabs |

## Settings

### Max Tokens

Controls the maximum response length from the LLM. Default: 4096. Adjust with the slider in AI Configuration.

- **Lower (256-1024)** — faster responses, may truncate complex analyses
- **Higher (4096-16384)** — complete analyses, slower and more expensive

### System Prompt

Optional context injected into every AI request. Use it to describe your application:

> "This is an e-commerce platform with 50M orders. The database handles 5000 QPS during peak hours."

### Domain Prompt

Optional instructions for the AI's recommendations:

> "Prefer window functions over correlated subqueries. Don't recommend foreign keys — we handle referential integrity in the application layer."

## Using with Ollama (free, local)

1. Install Ollama: `brew install ollama`
2. Pull a model: `ollama pull llama3.2`
3. Start Ollama: `ollama serve`
4. In MysqlGenius, select **Ollama (local)** as the provider
5. The endpoint and model auto-fill — just click **Save**

No API key needed. All data stays on your machine.

## Copying AI responses

Every AI response has a **Copy response** button at the bottom right. Click it to copy the plain text to your clipboard — useful for sharing with team members or pasting into tickets.

## Cost considerations

Each AI feature makes one API call per invocation. Typical costs with OpenAI gpt-4o-mini:

| Feature | ~Input tokens | ~Output tokens | ~Cost |
|---|---|---|---|
| Schema Review (all tables) | 2000-5000 | 500-2000 | $0.001-0.005 |
| Migration Risk | 500-1000 | 500-1000 | $0.001 |
| Query Optimization | 1000-2000 | 500-1000 | $0.001 |
| Workload Digest | 3000-5000 | 1000-2000 | $0.003 |

Using Ollama or other local models eliminates API costs entirely.
