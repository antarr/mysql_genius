# Connecting to MySQL Through an SSH Tunnel

If your MySQL server is behind a firewall, on a private network, or only accessible via a bastion/jump host, you can use an SSH tunnel to connect MysqlGenius to it.

## How it works

An SSH tunnel forwards a local port on your machine to the MySQL port on the remote server. MysqlGenius connects to `localhost:<local_port>` and the tunnel transparently routes traffic to the actual database server.

```
Your Machine (MysqlGenius)  →  SSH Tunnel  →  Bastion Host  →  MySQL Server
localhost:3307                                                   db.internal:3306
```

## Step 1: Open the SSH tunnel

In a terminal, run:

```bash
ssh -L 3307:db.internal:3306 user@bastion-host.example.com -N
```

**Flags explained:**
- `-L 3307:db.internal:3306` — forward local port `3307` to `db.internal:3306` through the tunnel
- `user@bastion-host.example.com` — your SSH login on the bastion/jump host
- `-N` — don't open a shell, just forward the port

**With an SSH key:**

```bash
ssh -L 3307:db.internal:3306 user@bastion-host.example.com -N -i ~/.ssh/my_key
```

**Keep it running in the background:**

```bash
ssh -L 3307:db.internal:3306 user@bastion-host.example.com -N -f
```

The `-f` flag sends SSH to the background after connecting.

## Step 2: Configure MysqlGenius

### Desktop app (Tauri / sidecar)

In the Connection Manager (`/connections`), create a profile with:

| Field | Value |
|---|---|
| Host | `127.0.0.1` |
| Port | `3307` (the local tunnel port) |
| Username | Your MySQL username |
| Password | Your MySQL password |
| Database | The database name |

### Rails adapter

In your Rails app's initializer:

```ruby
MysqlGenius.configure do |config|
  # No special config needed — MysqlGenius uses your app's
  # ActiveRecord::Base.connection, which is already configured
  # in database.yml. If your Rails app connects through a tunnel,
  # MysqlGenius automatically uses the same connection.
end
```

### YAML config (sidecar CLI)

```yaml
version: 1
mysql:
  host: 127.0.0.1
  port: 3307
  username: readonly
  password: your_password
  database: app_production
```

## Step 3: Verify the connection

### Desktop app

Click **Test Connection** on the profile form. If the tunnel is running, you should see "Connected (MySQL X.Y.Z)".

### Sidecar CLI

```bash
mysql-genius-sidecar --config /path/to/config.yml
```

If the tunnel is not running, you'll see: `Failed to connect to MySQL at 127.0.0.1:3307: Connection refused`.

## Common issues

### "Connection refused"

The SSH tunnel is not running. Start it first:

```bash
ssh -L 3307:db.internal:3306 user@bastion -N
```

### "Access denied"

The tunnel is working but the MySQL credentials are wrong. Verify your username/password can connect to the database directly from the bastion host.

### "Lost connection to MySQL server during query"

The SSH tunnel dropped. This happens if the tunnel is idle for too long. Add keep-alive settings:

```bash
ssh -L 3307:db.internal:3306 user@bastion -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3
```

### Port already in use

Another process is using port 3307. Pick a different local port:

```bash
ssh -L 3308:db.internal:3306 user@bastion -N
```

Then update your MysqlGenius config to use port `3308`.

## Multiple databases through one bastion

You can tunnel to multiple MySQL servers through the same bastion:

```bash
# Production on local port 3307
ssh -L 3307:db-prod.internal:3306 user@bastion -N -f

# Staging on local port 3308
ssh -L 3308:db-staging.internal:3306 user@bastion -N -f
```

Then create separate MysqlGenius profiles for each:
- **Production**: `127.0.0.1:3307`
- **Staging**: `127.0.0.1:3308`

## Automating the tunnel

### macOS: Launch Agent

Create `~/Library/LaunchAgents/com.mysqlgenius.tunnel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mysqlgenius.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>ssh</string>
        <string>-L</string>
        <string>3307:db.internal:3306</string>
        <string>user@bastion</string>
        <string>-N</string>
        <string>-o</string>
        <string>ServerAliveInterval=60</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.mysqlgenius.tunnel.plist
```

The tunnel will start automatically on login and restart if it drops.

## Future: Built-in SSH tunnel support

Built-in SSH tunnel support is planned for a future release. When available, you'll be able to configure the SSH connection directly in the MysqlGenius profile form without needing a separate terminal.
