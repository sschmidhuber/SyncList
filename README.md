# SyncList 📝

SyncList is a modern, collaborative, real-time list and grocery planning application. It is written in **Julia** using the lightweight and high-performance **Oxygen.jl** web framework, backed by a persistent **SQLite** database, and rendered dynamically via **HTMX** and **Tailwind CSS**. 

---

## 🚀 Key Features

* **Real-time Synchronisation (SSE)**: Uses Server-Sent Events (SSE) to sync list states across multiple clients instantly. Any changes made by one user are immediately updated on everyone else's screen without page refreshes.
* **Collaborative & Private Lists**: Supports creating both private lists (only visible to the owner) and shared/collaborative lists (visible and editable by all registered users).
* **Intuitive List Operations**: 
  - Drag-and-drop item reordering (sorting persisted in the database).
  - Quick editing and deletion of lists and items.
  - Adding new items to lists in real-time.
* **Smart Checked Items Auto-Hiding**: Checked/done items are automatically hidden 24 hours after completion to keep lists clean. A simple visibility toggle allows users to show or hide these archived items at any time.
* **Autosuggestions**: Offers smart, case-insensitive autocomplete suggestions when typing new items (pre-seeded with common German groceries).
* **Admin Panel**: An integrated administration interface accessible at `/admin` to add, view, and delete autosuggestions.
* **TOML-Based Multi-user Authentication**: Cookie-based persistent sessions managed securely with a database-backed session store, validating credentials against a standard `users.toml` configuration.

---

## 📦 Installation Description

SyncList is fully compliant with modern Julia package specifications and can be installed directly as a **Julia App** (command-line executable).

### Prerequisites
* **Julia 1.11+** installed on your system.
* Make sure your Julia bin depot directory (typically `~/.julia/bin`) is in your system's `PATH`.

### Method A: Install via Git Repo
Open Julia package manager mode (by typing `]` in the REPL) and add the application:
```julia
pkg> app add https://github.com/sschmidhuber/SyncList.git
```

### Method B: Local Development / Installation
If you have a local checkout of the repository, you can register it as an app via:
```julia
pkg> app develop /path/to/SyncList
```

This will automatically create a precompiled binary shim named `synclist` in `~/.julia/bin/synclist`.

---

## 🛠️ Running & Command-Line Arguments

Once installed, you can launch the SyncList server from anywhere using the `synclist` command.

### CLI Usage
```bash
synclist [options]
```

### Command-Line Options
| Option | Description | Default |
| :--- | :--- | :--- |
| `-p, --port <port>` | Port to listen on | `8080` |
| `-o, --host <host>` | Host interface to bind to | `0.0.0.0` |
| `-d, --db <path>` | Path to the SQLite database file | `synclist.db` *(relative to app root)* |
| `-u, --users <path>` | Path to the `users.toml` configuration file | `users.toml` *(relative to app root)* |
| `-h, --help` | Show the help message and exit | — |

---

## ⚙️ Configuration

### Authentication (`users.toml`)
Users and their plain-text passwords can be configured inside a `users.toml` file matching this format:

```toml
[users]
stefan = "julia123"
alice = "secret456"
```

### Environment Variables
You can also override paths using environment variables instead of command-line flags:
* `SYNCLIST_DB`: Path to custom SQLite database.
* `SYNCLIST_USERS`: Path to custom `users.toml` configuration.

---

## 🐧 Production Deployment with Systemd

For Linux production environments, you can easily control SyncList using `systemd`. A pre-configured `synclist.service` unit template is provided in the repository root.

### How to Deploy
1. **Copy the service file** to the systemd directory:
   ```bash
   sudo cp synclist.service /etc/systemd/system/
   ```
2. **Reload systemd daemon** to register the new service:
   ```bash
   sudo systemctl daemon-reload
   ```
3. **Start and enable** the service to run on system boot:
   ```bash
   sudo systemctl start synclist
   sudo systemctl enable synclist
   ```
4. **Monitor the service logs**:
   ```bash
   sudo systemctl status synclist
   journalctl -u synclist -f
   ```

---

## 🧪 Running Tests

To run the SyncList test suite, navigate to the project directory and run:
```bash
julia --project -e 'using Pkg; Pkg.test()'
```
