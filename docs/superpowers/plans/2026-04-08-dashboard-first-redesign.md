# Dashboard-First Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the default landing page a PgHero-style monitoring dashboard instead of a query builder, reorder tabs to lead with monitoring, and merge Visual Builder + SQL Query into one "Query Explorer" tab.

**Architecture:** The dashboard tab is a new partial that reuses all existing AJAX endpoints (server_overview, slow_queries, query_stats, duplicate_indexes, unused_indexes) with no new routes. The query explorer merges two existing partials into one with a mode toggle. The only backend change is adding a `limit` param to the `query_stats` action.

**Tech Stack:** Rails ERB partials, vanilla JavaScript (matching existing patterns), existing CSS utility classes.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `app/controllers/concerns/mysql_genius/database_analysis.rb` | Modify | Add `limit` param to `query_stats` |
| `app/views/mysql_genius/queries/_tab_dashboard.html.erb` | Create | Dashboard HTML structure |
| `app/views/mysql_genius/queries/_tab_query_explorer.html.erb` | Create | Merged visual builder + SQL query with mode toggle |
| `app/views/mysql_genius/queries/index.html.erb` | Modify | Tab bar reorder, partial renders, JS for dashboard + query explorer |
| `app/views/mysql_genius/queries/_tab_visual_builder.html.erb` | Delete | Content moved to query explorer |
| `app/views/mysql_genius/queries/_tab_sql_query.html.erb` | Delete | Content moved to query explorer |
| `mysql_genius.gemspec` | Modify | Update description |
| `README.md` | Modify | Update usage section and screenshot order |

---

### Task 1: Add `limit` param to `query_stats` action

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb:112`

- [ ] **Step 1: Add limit param support**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, change the hardcoded `LIMIT 50` to use a param with a cap:

```ruby
      limit = [params.fetch(:limit, 50).to_i, 50].min

      results = connection.exec_query(<<~SQL)
        SELECT
          DIGEST_TEXT,
          COUNT_STAR AS calls,
          ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_time_ms,
          ROUND(AVG_TIMER_WAIT / 1000000000, 1) AS avg_time_ms,
          ROUND(MAX_TIMER_WAIT / 1000000000, 1) AS max_time_ms,
          SUM_ROWS_EXAMINED AS rows_examined,
          SUM_ROWS_SENT AS rows_sent,
          SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
          SUM_SORT_ROWS AS sort_rows,
          FIRST_SEEN,
          LAST_SEEN
        FROM performance_schema.events_statements_summary_by_digest
        WHERE SCHEMA_NAME = #{connection.quote(connection.current_database)}
          AND DIGEST_TEXT IS NOT NULL
          AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
        ORDER BY #{order_clause}
        LIMIT #{limit}
      SQL
```

The key change: replace `LIMIT 50` (line 112) with `LIMIT #{limit}` and add the `limit` local variable before the query. The `[..., 50].min` cap ensures the dashboard's `limit=5` works while the full Query Stats tab still gets up to 50.

- [ ] **Step 2: Run RuboCop to verify**

Run: `bundle exec rubocop app/controllers/concerns/mysql_genius/database_analysis.rb`
Expected: no offenses

- [ ] **Step 3: Commit**

```bash
git add app/controllers/concerns/mysql_genius/database_analysis.rb
git commit -m "Add limit param to query_stats action for dashboard use"
```

---

### Task 2: Create the Dashboard tab partial

**Files:**
- Create: `app/views/mysql_genius/queries/_tab_dashboard.html.erb`

- [ ] **Step 1: Create the dashboard partial**

Create `app/views/mysql_genius/queries/_tab_dashboard.html.erb` with this content:

```erb
<!-- Dashboard Tab -->
<div class="mg-tab-content active" id="tab-dashboard">
  <div id="dash-loading" class="mg-text-center"><span class="mg-spinner"></span> Loading dashboard...</div>
  <div id="dash-error" class="mg-hidden"></div>
  <div id="dash-content" class="mg-hidden">

    <!-- Server Summary -->
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px;margin-bottom:16px;">
      <div class="mg-card">
        <div class="mg-card-header"><strong>Server</strong></div>
        <div class="mg-card-body">
          <div class="mg-stat-grid" id="dash-server-info"></div>
        </div>
      </div>
      <div class="mg-card">
        <div class="mg-card-header"><strong>Connections</strong></div>
        <div class="mg-card-body">
          <div id="dash-conn-bar" style="margin-bottom:8px;"></div>
          <div class="mg-stat-grid" id="dash-conn-info"></div>
        </div>
      </div>
      <div class="mg-card">
        <div class="mg-card-header"><strong>InnoDB Buffer Pool</strong></div>
        <div class="mg-card-body">
          <div id="dash-innodb-bar" style="margin-bottom:8px;"></div>
          <div class="mg-stat-grid" id="dash-innodb-info"></div>
        </div>
      </div>
      <div class="mg-card">
        <div class="mg-card-header"><strong>Query Activity</strong></div>
        <div class="mg-card-body">
          <div class="mg-stat-grid" id="dash-query-info"></div>
        </div>
      </div>
    </div>

    <!-- Top 5 Slow Queries -->
    <div class="mg-card mg-mb">
      <div class="mg-card-header" style="display:flex;justify-content:space-between;align-items:center;">
        <strong>Slow Queries</strong>
        <button class="mg-btn mg-btn-outline-secondary mg-btn-sm dash-jump-tab" data-target="slow">View all &rarr;</button>
      </div>
      <div class="mg-card-body">
        <div id="dash-slow-empty" class="mg-text-muted mg-hidden"></div>
        <div id="dash-slow-table" class="mg-table-wrap mg-hidden">
          <table class="mg-table">
            <thead><tr><th style="width:100px">Duration</th><th style="width:160px">Time</th><th>SQL</th></tr></thead>
            <tbody id="dash-slow-tbody"></tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- Top 5 Expensive Queries -->
    <div class="mg-card mg-mb">
      <div class="mg-card-header" style="display:flex;justify-content:space-between;align-items:center;">
        <strong>Most Expensive Queries</strong>
        <button class="mg-btn mg-btn-outline-secondary mg-btn-sm dash-jump-tab" data-target="qstats">View all &rarr;</button>
      </div>
      <div class="mg-card-body">
        <div id="dash-qstats-empty" class="mg-text-muted mg-hidden"></div>
        <div id="dash-qstats-error" class="mg-hidden"></div>
        <div id="dash-qstats-table" class="mg-table-wrap mg-hidden">
          <table class="mg-table">
            <thead><tr><th>Query</th><th style="text-align:right">Calls</th><th style="text-align:right">Total Time</th><th style="text-align:right">Avg Time</th></tr></thead>
            <tbody id="dash-qstats-tbody"></tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- Index Alerts -->
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px;">
      <div class="mg-card dash-jump-tab" data-target="indexes" style="cursor:pointer;">
        <div class="mg-card-body mg-text-center">
          <div id="dash-dup-count" style="font-size:24px;font-weight:700;">--</div>
          <div class="mg-text-muted">Duplicate Indexes</div>
        </div>
      </div>
      <div class="mg-card dash-jump-tab" data-target="unused" style="cursor:pointer;">
        <div class="mg-card-body mg-text-center">
          <div id="dash-unused-count" style="font-size:24px;font-weight:700;">--</div>
          <div class="mg-text-muted">Unused Indexes</div>
        </div>
      </div>
    </div>

  </div>
</div>
```

- [ ] **Step 2: Verify file renders valid HTML**

Run: `ruby -e "puts File.read('app/views/mysql_genius/queries/_tab_dashboard.html.erb').length"` from project root.
Expected: prints a number (file exists and is readable)

- [ ] **Step 3: Commit**

```bash
git add app/views/mysql_genius/queries/_tab_dashboard.html.erb
git commit -m "Add dashboard tab partial with server summary, top queries, and index alerts"
```

---

### Task 3: Create the Query Explorer tab partial

**Files:**
- Create: `app/views/mysql_genius/queries/_tab_query_explorer.html.erb`

- [ ] **Step 1: Create the query explorer partial**

Create `app/views/mysql_genius/queries/_tab_query_explorer.html.erb`. This combines the content from `_tab_visual_builder.html.erb` and `_tab_sql_query.html.erb` with a mode toggle. The visual builder content keeps its existing `id="tab-visual"` inner div (now `id="qe-visual"`) and the SQL content keeps `id="tab-sql"` inner div (now `id="qe-sql"`) so existing JS references work after updating.

```erb
<!-- Query Explorer Tab -->
<div class="mg-tab-content" id="tab-explorer">
  <div style="margin-bottom:12px;">
    <button class="mg-btn mg-btn-sm qe-mode active" data-mode="visual">Visual Builder</button>
    <button class="mg-btn mg-btn-sm mg-btn-outline qe-mode" data-mode="sql">SQL Editor</button>
  </div>

  <!-- Visual Builder Mode -->
  <div id="qe-visual">
    <div class="mg-row mg-mb">
      <div class="mg-col-4 mg-field">
        <label for="vb-table">Table</label>
        <select id="vb-table">
          <option value="">-- Select a table --</option>
          <% if @featured_tables != @all_tables %>
            <optgroup label="Featured">
              <% @featured_tables.each do |table| %>
                <option value="<%= table %>"><%= table %></option>
              <% end %>
            </optgroup>
            <optgroup label="All Tables">
              <% (@all_tables - @featured_tables).each do |table| %>
                <option value="<%= table %>"><%= table %></option>
              <% end %>
            </optgroup>
          <% else %>
            <% @all_tables.each do |table| %>
              <option value="<%= table %>"><%= table %></option>
            <% end %>
          <% end %>
        </select>
      </div>
      <div class="mg-col-2 mg-field">
        <label for="vb-row-limit">Row Limit</label>
        <input type="number" id="vb-row-limit" value="25" min="1" max="<%= MysqlGenius.configuration.max_row_limit %>">
      </div>
      <div class="mg-field">
        <label>&nbsp;</label>
        <button id="vb-run" class="mg-btn mg-btn-primary" disabled>&#9654; Run Query</button>
        <button id="vb-explain" class="mg-btn mg-btn-outline" disabled>&#128270; Explain</button>
      </div>
    </div>

    <div id="vb-columns-section" class="mg-mb mg-hidden">
      <label>Columns
        <span id="vb-toggle-all" class="mg-link">Toggle All</span>
        <span id="vb-show-defaults" class="mg-link">Reset Defaults</span>
      </label>
      <div id="vb-columns" class="mg-checks"></div>
    </div>

    <div id="vb-filters-section" class="mg-mb mg-hidden">
      <label>Filters</label>
      <div id="vb-filters"></div>
      <button id="vb-add-filter" class="mg-btn mg-btn-outline-secondary mg-btn-sm" style="margin-top:4px;">+ Add Filter</button>
    </div>

    <div id="vb-order-section" class="mg-mb mg-hidden">
      <label>Order By</label>
      <div id="vb-orders"></div>
      <button id="vb-add-order" class="mg-btn mg-btn-outline-secondary mg-btn-sm" style="margin-top:4px;">+ Add Sort</button>
    </div>

    <div id="vb-generated-sql" class="mg-mb mg-hidden">
      <label>Generated SQL</label>
      <textarea id="vb-sql-preview" rows="2" readonly></textarea>
    </div>
  </div>

  <!-- SQL Editor Mode -->
  <div id="qe-sql" class="mg-hidden">
    <% if @ai_enabled %>
      <div class="mg-card mg-mb">
        <div class="mg-card-header">
          <span class="mg-card-toggle" id="ai-toggle">&#9889; AI Assistant <span class="mg-text-muted">- Describe what you want in plain English</span></span>
        </div>
        <div class="mg-card-body mg-hidden" id="ai-panel">
          <div class="mg-field">
            <textarea id="ai-prompt" rows="2" placeholder="e.g. Show me all users created in the last 30 days"></textarea>
            <div class="mg-text-muted" style="margin-top:2px;">Only table names and column names are sent to the AI. No row data leaves the system.</div>
          </div>
          <button id="ai-suggest" class="mg-btn mg-btn-primary mg-btn-sm mg-mb">&#9889; Suggest Query</button>
          <div id="ai-result" class="mg-hidden">
            <div id="ai-explanation" class="mg-alert mg-alert-info"></div>
          </div>
        </div>
      </div>
    <% end %>

    <div class="mg-field">
      <label for="sql-input">SQL Query</label>
      <textarea id="sql-input" rows="5" placeholder="SELECT * FROM users LIMIT 10"></textarea>
    </div>
    <div class="mg-row">
      <div class="mg-col-2 mg-field">
        <label for="sql-row-limit">Row Limit</label>
        <input type="number" id="sql-row-limit" value="25" min="1" max="<%= MysqlGenius.configuration.max_row_limit %>">
      </div>
      <div class="mg-field">
        <label>&nbsp;</label>
        <button id="sql-run" class="mg-btn mg-btn-primary">&#9654; Run Query</button>
        <button id="sql-explain" class="mg-btn mg-btn-outline">&#128270; Explain</button>
        <% if @ai_enabled %>
          <button id="sql-describe" class="mg-btn mg-btn-outline mg-btn-sm" style="margin-left:8px;">&#9889; Describe</button>
          <button id="sql-rewrite" class="mg-btn mg-btn-outline mg-btn-sm">&#9889; Rewrite</button>
        <% end %>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 2: Commit**

```bash
git add app/views/mysql_genius/queries/_tab_query_explorer.html.erb
git commit -m "Add query explorer partial merging visual builder and SQL editor"
```

---

### Task 4: Update index.html.erb — tab bar and partials

**Files:**
- Modify: `app/views/mysql_genius/queries/index.html.erb:1-29`
- Delete: `app/views/mysql_genius/queries/_tab_visual_builder.html.erb`
- Delete: `app/views/mysql_genius/queries/_tab_sql_query.html.erb`

- [ ] **Step 1: Replace the tab bar and partial renders**

Replace lines 1-29 of `app/views/mysql_genius/queries/index.html.erb` (the header, tab buttons, and partial renders) with:

```erb
<h4>&#128024; MySQLGenius</h4>

<div class="mg-tabs">
  <button class="mg-tab active" data-tab="dashboard">Dashboard</button>
  <button class="mg-tab" data-tab="slow">Slow Queries</button>
  <button class="mg-tab" data-tab="qstats">Query Stats</button>
  <button class="mg-tab" data-tab="server">Server</button>
  <button class="mg-tab" data-tab="sizes">Table Sizes</button>
  <button class="mg-tab" data-tab="unused">Unused Indexes</button>
  <button class="mg-tab" data-tab="indexes">Duplicate Indexes</button>
  <button class="mg-tab" data-tab="explorer">Query Explorer</button>
  <% if @ai_enabled %>
    <button class="mg-tab" data-tab="aitools">AI Tools</button>
  <% end %>
</div>

<%= render "mysql_genius/queries/tab_dashboard" %>
<%= render "mysql_genius/queries/tab_slow_queries" %>
<%= render "mysql_genius/queries/tab_query_stats" %>
<%= render "mysql_genius/queries/tab_server" %>
<%= render "mysql_genius/queries/tab_table_sizes" %>
<%= render "mysql_genius/queries/tab_unused_indexes" %>
<%= render "mysql_genius/queries/tab_duplicate_indexes" %>
<%= render "mysql_genius/queries/tab_query_explorer" %>
<% if @ai_enabled %>
  <%= render "mysql_genius/queries/tab_ai_tools" %>
<% end %>

<%= render "mysql_genius/queries/shared_results" %>
```

- [ ] **Step 2: Delete the old partials**

```bash
rm app/views/mysql_genius/queries/_tab_visual_builder.html.erb
rm app/views/mysql_genius/queries/_tab_sql_query.html.erb
```

- [ ] **Step 3: Commit**

```bash
git add app/views/mysql_genius/queries/index.html.erb
git add app/views/mysql_genius/queries/_tab_visual_builder.html.erb
git add app/views/mysql_genius/queries/_tab_sql_query.html.erb
git commit -m "Reorder tabs to lead with dashboard, remove old visual builder and SQL partials"
```

---

### Task 5: Update JavaScript — tab switching, dashboard loader, query explorer toggle

**Files:**
- Modify: `app/views/mysql_genius/queries/index.html.erb` (JS section)

- [ ] **Step 1: Update the tab click handler**

Replace the tab click handler (lines 120-133) with:

```javascript
  qsa('.mg-tab').forEach(function(tab) {
    tab.addEventListener('click', function() {
      qsa('.mg-tab').forEach(function(t) { t.classList.remove('active'); });
      qsa('.mg-tab-content').forEach(function(c) { c.classList.remove('active'); });
      tab.classList.add('active');
      el('tab-' + tab.dataset.tab).classList.add('active');
      if (tab.dataset.tab === 'dashboard') loadDashboard();
      if (tab.dataset.tab === 'slow') loadSlowQueries();
      if (tab.dataset.tab === 'indexes') loadDuplicateIndexes();
      if (tab.dataset.tab === 'sizes') loadTableSizes();
      if (tab.dataset.tab === 'qstats') loadQueryStats();
      if (tab.dataset.tab === 'unused') loadUnusedIndexes();
      if (tab.dataset.tab === 'server') loadServerOverview();
    });
  });
```

- [ ] **Step 2: Add the `loadDashboard` function**

Insert this function before the `// --- Visual Builder ---` comment (around line 135). This function fires 4 parallel AJAX calls and populates the dashboard sections:

```javascript
  // --- Dashboard ---

  function loadDashboard() {
    show(el('dash-loading'));
    hide(el('dash-content')); hide(el('dash-error'));

    var loaded = { server: false, slow: false, qstats: false, dup: false, unused: false };

    function checkAllLoaded() {
      if (!loaded.server || !loaded.slow || !loaded.qstats || !loaded.dup || !loaded.unused) return;
      hide(el('dash-loading'));
      show(el('dash-content'));
    }

    // Server overview
    ajaxGet(ROUTES.server_overview, {}, function(data) {
      if (data.error) { loaded.server = true; checkAllLoaded(); return; }
      var s = data.server;
      var c = data.connections;
      var db = data.innodb;
      var q = data.queries;

      el('dash-server-info').innerHTML =
        statRow('Version', '<code>' + escHtml(s.version) + '</code>') +
        statRow('Uptime', escHtml(s.uptime)) +
        statRow('Queries/sec', q.qps);

      el('dash-conn-bar').innerHTML = usageBar(c.usage_pct, c.current + ' / ' + c.max + ' (' + c.usage_pct + '%)');
      el('dash-conn-info').innerHTML =
        statRow('Threads Running', c.threads_running) +
        statRow('Max Used', c.max_used);

      var poolUsedPct = db.buffer_pool_pages_total > 0
        ? (((db.buffer_pool_pages_total - db.buffer_pool_pages_free) / db.buffer_pool_pages_total) * 100).toFixed(1)
        : 0;
      el('dash-innodb-bar').innerHTML = usageBar(parseFloat(poolUsedPct), db.buffer_pool_mb + ' MB (' + poolUsedPct + '% used)');
      el('dash-innodb-info').innerHTML =
        statRow('Hit Rate', db.buffer_pool_hit_rate + '%') +
        statRow('Dirty Pages', Number(db.buffer_pool_pages_dirty).toLocaleString());

      var tmpBadge = q.tmp_disk_pct > 25
        ? '<span class="mg-badge mg-badge-danger">' + q.tmp_disk_pct + '%</span>'
        : q.tmp_disk_pct + '%';
      el('dash-query-info').innerHTML =
        statRow('Slow Queries', Number(q.slow_queries).toLocaleString()) +
        statRow('Tmp Disk Tables', tmpBadge);

      loaded.server = true;
      checkAllLoaded();
    }, function() { loaded.server = true; checkAllLoaded(); });

    // Top 5 slow queries
    ajaxGet(ROUTES.slow_queries, {}, function(data) {
      if (!data || !data.length) {
        el('dash-slow-empty').textContent = '<%= MysqlGenius.configuration.redis_url ? "No slow queries recorded." : "Configure redis_url to monitor slow queries." %>';
        show(el('dash-slow-empty'));
      } else {
        var top5 = data.slice(0, 5);
        el('dash-slow-tbody').innerHTML = top5.map(function(q) {
          var d = q.duration_ms;
          var cls = d >= 2000 ? 'mg-badge-danger' : d >= 1000 ? 'mg-badge-warning' : 'mg-badge-info';
          var sqlShort = escHtml(q.sql).length > 120 ? escHtml(q.sql).substring(0, 120) + '...' : escHtml(q.sql);
          return '<tr><td><span class="mg-badge ' + cls + '">' + d + ' ms</span></td>' +
            '<td><small>' + escHtml(q.timestamp) + '</small></td>' +
            '<td><code>' + sqlShort + '</code></td></tr>';
        }).join('');
        show(el('dash-slow-table'));
      }
      loaded.slow = true;
      checkAllLoaded();
    }, function() {
      el('dash-slow-empty').textContent = 'Configure redis_url to monitor slow queries.';
      show(el('dash-slow-empty'));
      loaded.slow = true;
      checkAllLoaded();
    });

    // Top 5 expensive queries
    ajaxGet(ROUTES.query_stats, { sort: 'total_time', limit: 5 }, function(data) {
      if (data.error) {
        el('dash-qstats-error').innerHTML = '<div class="mg-text-muted">' + escHtml(data.error) + '</div>';
        show(el('dash-qstats-error'));
      } else if (!data.length) {
        el('dash-qstats-empty').textContent = 'No query statistics available.';
        show(el('dash-qstats-empty'));
      } else {
        el('dash-qstats-tbody').innerHTML = data.map(function(q) {
          var sqlShort = q.sql.length > 120 ? q.sql.substring(0, 120) + '...' : q.sql;
          return '<tr>' +
            '<td><code style="font-size:11px;word-break:break-all;">' + escHtml(sqlShort) + '</code></td>' +
            '<td style="text-align:right">' + Number(q.calls).toLocaleString() + '</td>' +
            '<td style="text-align:right">' + formatDuration(q.total_time_ms) + '</td>' +
            '<td style="text-align:right">' + formatDuration(q.avg_time_ms) + '</td></tr>';
        }).join('');
        show(el('dash-qstats-table'));
      }
      loaded.qstats = true;
      checkAllLoaded();
    }, function() {
      el('dash-qstats-empty').textContent = 'Query statistics unavailable.';
      show(el('dash-qstats-empty'));
      loaded.qstats = true;
      checkAllLoaded();
    });

    // Duplicate indexes count
    ajaxGet(ROUTES.duplicate_indexes, {}, function(data) {
      var count = Array.isArray(data) ? data.length : 0;
      var countEl = el('dash-dup-count');
      if (count === 0) {
        countEl.innerHTML = '<span style="color:#28a745;">&#10003; 0</span>';
      } else {
        countEl.innerHTML = '<span style="color:#dc3545;">' + count + '</span>';
      }
      loaded.dup = true;
      checkAllLoaded();
    }, function() { el('dash-dup-count').textContent = '?'; loaded.dup = true; checkAllLoaded(); });

    // Unused indexes count
    ajaxGet(ROUTES.unused_indexes, {}, function(data) {
      var count = Array.isArray(data) ? data.length : 0;
      var countEl = el('dash-unused-count');
      if (count === 0) {
        countEl.innerHTML = '<span style="color:#28a745;">&#10003; 0</span>';
      } else {
        countEl.innerHTML = '<span style="color:#dc3545;">' + count + '</span>';
      }
      loaded.unused = true;
      checkAllLoaded();
    }, function() { el('dash-unused-count').textContent = '?'; loaded.unused = true; checkAllLoaded(); });
  }

  // Dashboard tab-jump buttons
  document.addEventListener('click', function(e) {
    var jumpBtn = e.target.closest('.dash-jump-tab');
    if (jumpBtn) {
      var target = jumpBtn.dataset.target;
      qsa('.mg-tab').forEach(function(t) { t.classList.remove('active'); });
      qsa('.mg-tab-content').forEach(function(c) { c.classList.remove('active'); });
      qs('[data-tab="' + target + '"]').classList.add('active');
      el('tab-' + target).classList.add('active');
      if (target === 'slow') loadSlowQueries();
      if (target === 'indexes') loadDuplicateIndexes();
      if (target === 'qstats') loadQueryStats();
      if (target === 'unused') loadUnusedIndexes();
    }
  });

  // Load dashboard on page load
  loadDashboard();
```

- [ ] **Step 3: Add the query explorer mode toggle**

Insert this after the dashboard section, before the existing visual builder JS (the `var typeLabels = ...` line):

```javascript
  // --- Query Explorer Mode Toggle ---

  qsa('.qe-mode').forEach(function(btn) {
    btn.addEventListener('click', function() {
      qsa('.qe-mode').forEach(function(b) {
        b.classList.remove('active');
        b.classList.add('mg-btn-outline');
      });
      btn.classList.add('active');
      btn.classList.remove('mg-btn-outline');
      if (btn.dataset.mode === 'visual') {
        show(el('qe-visual'));
        hide(el('qe-sql'));
      } else {
        hide(el('qe-visual'));
        show(el('qe-sql'));
      }
    });
  });
```

- [ ] **Step 4: Update the slow query "Use" button handler**

Find the existing handler (around line 522-529) that switches to the SQL tab when clicking "Use" on a slow query. Update it to switch to the Query Explorer tab in SQL mode instead:

Change:
```javascript
      qs('[data-tab="sql"]').classList.add('active');
      el('tab-sql').classList.add('active');
```

To:
```javascript
      qs('[data-tab="explorer"]').classList.add('active');
      el('tab-explorer').classList.add('active');
      // Switch to SQL mode within Query Explorer
      qsa('.qe-mode').forEach(function(b) { b.classList.remove('active'); b.classList.add('mg-btn-outline'); });
      qs('.qe-mode[data-mode="sql"]').classList.add('active');
      qs('.qe-mode[data-mode="sql"]').classList.remove('mg-btn-outline');
      hide(el('qe-visual'));
      show(el('qe-sql'));
```

- [ ] **Step 5: Run specs and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all specs pass, no offenses

- [ ] **Step 6: Commit**

```bash
git add app/views/mysql_genius/queries/index.html.erb
git commit -m "Add dashboard JS loader, query explorer toggle, and auto-load on page mount"
```

---

### Task 6: Update gemspec description

**Files:**
- Modify: `mysql_genius.gemspec:14-16`

- [ ] **Step 1: Update the description**

Change the description in `mysql_genius.gemspec` from:

```ruby
  spec.description   = "MysqlGenius gives Rails apps a mountable admin dashboard for MySQL databases. " \
    "Includes a safe SQL query explorer with visual builder, EXPLAIN analysis, " \
    "slow query monitoring, audit logging, and optional AI-powered query suggestions and optimization."
```

To:

```ruby
  spec.description   = "MysqlGenius gives Rails apps a mountable performance dashboard for MySQL databases. " \
    "Monitor slow queries, analyze query statistics from performance_schema, detect unused and duplicate indexes, " \
    "and explore your database with optional AI-powered optimization."
```

- [ ] **Step 2: Commit**

```bash
git add mysql_genius.gemspec
git commit -m "Update gemspec description to lead with monitoring features"
```

---

### Task 7: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Reorder screenshots section**

Move the screenshots section so Dashboard is first. Replace the current screenshots block (lines 6-41) with:

```markdown
### Dashboard
At-a-glance server health, top slow queries, most expensive queries, and index alerts.

![Dashboard](docs/screenshots/dashboard.png)

### Slow Queries
SELECT queries exceeding the configured threshold, captured via ActiveSupport notifications and Redis.

### Query Stats
Top queries from `performance_schema` sorted by total time, with call counts, avg/max time, and rows examined.

![Query Stats](docs/screenshots/query_stats.png)

### Server Dashboard
Server health: version, connections, InnoDB buffer pool, and query activity with AI-powered diagnostics.

![Server](docs/screenshots/server.png)

### Table Sizes
View row counts, data size, index size, fragmentation, and a visual size chart for every table.

![Table Sizes](docs/screenshots/table_sizes.png)

### Duplicate Index Detection
Find redundant indexes whose columns are a left-prefix of another index, with ready-to-run `DROP INDEX` statements.

![Duplicate Indexes](docs/screenshots/duplicate_indexes.png)

### Query Explorer
Build queries visually or write raw SQL. Optional AI assistant generates queries from plain English descriptions.

![Visual Builder](docs/screenshots/visual_builder.png)

### AI Tools
Schema review that finds anti-patterns -- missing primary keys, nullable foreign keys, inappropriate column types, and more.

![AI Tools](docs/screenshots/ai_tools.png)
```

- [ ] **Step 2: Update the Usage section**

Replace the current "Usage" section (starting around line 218) with:

```markdown
## Usage

Visit `/mysql_genius` in your browser. The dashboard loads automatically with an overview of your database health.

### Dashboard
The default landing page shows server health cards, top 5 slow queries, top 5 most expensive queries (from performance_schema), and index alert badges for duplicate and unused indexes. Each section links to its detailed tab.

### Query Explorer
Combines the visual query builder and raw SQL editor in one tab. Toggle between Visual mode (point-and-click with column selection, filters, and ordering) and SQL mode (raw SQL with optional AI assistant). Generated SQL syncs between modes.

### Monitoring Tabs
- **Slow Queries** -- slow SELECT queries captured from your application in real time, with Explain and Optimize actions
- **Query Stats** -- top queries from `performance_schema` sorted by total time, avg time, calls, or rows examined
- **Server** -- connections, InnoDB buffer pool, query activity, with AI-powered diagnostics
- **Table Sizes** -- row counts, data size, index size, fragmentation for all tables
- **Unused Indexes** -- indexes with zero reads since server restart
- **Duplicate Indexes** -- redundant indexes with ready-to-run DROP statements
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Update README to reflect dashboard-first layout and new tab order"
```
