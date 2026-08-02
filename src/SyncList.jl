module SyncList

using Oxygen
@oxidize
using Mustache
using SQLite
using Dates
using Random
using SHA
using UUIDs
using TOML

import HTTP

# Global configuration state
const CONFIG = Ref{Dict{String, Any}}()

function load_config()
    default_config = Dict{String, Any}(
        "server" => Dict{String, Any}(
            "host" => "0.0.0.0",
            "port" => 8080,
            "base_path" => ""
        )
    )
    
    # Check env variable first, then default to ~/.synclist/config.toml
    config_path = Base.get(ENV, "SYNCLIST_CONFIG", joinpath(homedir(), ".synclist", "config.toml"))
    
    if !isfile(config_path)
        # Initialize default config.toml on first start
        try
            config_dir = dirname(config_path)
            if !isempty(config_dir)
                mkpath(config_dir)
            end
            write(config_path, """
            [server]
            host = "0.0.0.0"
            port = 8080
            base_path = ""
            """)
        catch e
            @warn "Failed to initialize default config.toml at $config_path: $e"
        end
    end
    
    if isfile(config_path)
        try
            loaded = TOML.parsefile(config_path)
            if haskey(loaded, "server") && loaded["server"] isa Dict
                merge!(default_config["server"], loaded["server"])
            end
            if haskey(loaded, "database")
                default_config["database"] = loaded["database"]
            end
        catch e
            @warn "Failed to parse config.toml: $e"
        end
    end
    CONFIG[] = default_config
end

function get_base_path()
    if !isassigned(CONFIG)
        load_config()
    end
    server_cfg = Base.get(CONFIG[], "server", Dict{String, Any}())
    base_path = strip(Base.get(server_cfg, "base_path", ""))
    if !isempty(base_path)
        if !startswith(base_path, "/")
            base_path = "/" * base_path
        end
        if endswith(base_path, "/") && length(base_path) > 1
            base_path = base_path[1:prevind(base_path, end)]
        end
    end
    return base_path
end

# Middleware to strip prefix
function prefix_stripper_middleware(handler)
    return function(req::HTTP.Request)
        # Normalize double slashes in the path portion of req.target
        target_parts = split(req.target, '?', limit=2)
        path_part = replace(target_parts[1], r"/+" => "/")
        target = length(target_parts) > 1 ? path_part * "?" * target_parts[2] : path_part
        req.target = target

        base_path = get_base_path()
        if !isempty(base_path) && startswith(req.target, base_path)
            new_target = req.target[nextind(req.target, length(base_path)):end]
            if isempty(new_target) || !startswith(new_target, '/')
                new_target = "/" * new_target
            end
            req.target = new_target
        end
        return handler(req)
    end
end

# Database and Lock initialization
const DB_LOCK = ReentrantLock()
const PROJECT_ROOT = dirname(@__DIR__)

const DB_CONN = Ref{SQLite.DB}()

# Helper to hash password with SHA-256 and a random salt
function hash_password(password::String, salt::String)
    return bytes2hex(sha256(password * salt))
end

function init_db_and_users(db_path=nothing, users_path=nothing)
    if db_path === nothing
        db_path = Base.get(ENV, "SYNCLIST_DB", joinpath(homedir(), ".synclist", "synclist.db"))
    end

    # Ensure directory exists
    db_dir = dirname(db_path)
    if !isempty(db_dir)
        mkpath(db_dir)
    end

    lock(DB_LOCK) do
        # If DB connection is already open, close it first
        if isassigned(DB_CONN)
            try
                SQLite.close(DB_CONN[])
            catch
            end
        end

        db = SQLite.DB(db_path)
        # Enable foreign keys for CASCADE DELETE
        SQLite.execute(db, "PRAGMA foreign_keys = ON;")
        
        # Create lists table
        SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS lists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            owner TEXT NOT NULL,
            is_shared INTEGER DEFAULT 0,
            show_hidden INTEGER DEFAULT 0
        );
        """)
        
        # Create items table
        SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            list_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            is_done INTEGER DEFAULT 0,
            checked_at TEXT,
            position INTEGER DEFAULT 0,
            FOREIGN KEY(list_id) REFERENCES lists(id) ON DELETE CASCADE
        );
        """)

        # Migrations for existing databases
        try
            SQLite.execute(db, "ALTER TABLE lists ADD COLUMN show_hidden INTEGER DEFAULT 0;")
        catch
            # Column already exists or table is not created yet
        end

        try
            SQLite.execute(db, "ALTER TABLE items ADD COLUMN checked_at TEXT;")
        catch
            # Column already exists
        end

        try
            SQLite.execute(db, "ALTER TABLE items ADD COLUMN position INTEGER DEFAULT 0;")
        catch
            # Column already exists
        end

        # Create sessions table
        SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS sessions (
            token TEXT PRIMARY KEY,
            username TEXT NOT NULL
        );
        """)

        # Create autosuggestions table
        SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS autosuggestions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE
        );
        """)

        # Create users table
        SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'user'
        );
        """)

        # Create password_resets table
        SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS password_resets (
            token TEXT PRIMARY KEY,
            username TEXT NOT NULL
        );
        """)

        # Seed default admin user if empty
        r_users = SQLite.DBInterface.execute(db, "SELECT COUNT(*) as count FROM users;") |> first
        if r_users.count == 0
            admin_salt = string(uuid4())
            admin_hash = bytes2hex(sha256("admin" * admin_salt))
            SQLite.DBInterface.execute(db, "INSERT INTO users (username, password_hash, salt, role) VALUES (?, ?, ?, ?);", ("admin", admin_hash, admin_salt, "admin"))
        end

        DB_CONN[] = db
    end
end

# Database Query Helpers (returns Dict with String keys for Mustache compatibility)
function db_query(sql::String, params=())
    lock(DB_LOCK) do
        cursor = SQLite.DBInterface.execute(DB_CONN[], sql, params)
        rows = Dict{String, Any}[]
        for row in cursor
            d = Dict{String, Any}()
            for col in propertynames(row)
                val = row[col]
                d[string(col)] = ismissing(val) ? nothing : val
            end
            push!(rows, d)
        end
        return rows
    end
end

function db_execute(sql::String, params=())
    lock(DB_LOCK) do
        SQLite.DBInterface.execute(DB_CONN[], sql, params)
    end
end

# Session Store (In-Memory)
# session_token => username
const SESSIONS = Dict{String, String}()

# SSE Client Store
const SSE_CLIENTS = Set{Channel{String}}()
const SSE_LOCK = ReentrantLock()

function register_sse_client(chan::Channel{String})
    lock(SSE_LOCK) do
        push!(SSE_CLIENTS, chan)
    end
end

function unregister_sse_client(chan::Channel{String})
    lock(SSE_LOCK) do
        delete!(SSE_CLIENTS, chan)
    end
end

function notify_sse_clients()
    lock(SSE_LOCK) do
        for chan in SSE_CLIENTS
            try
                if isopen(chan)
                    put!(chan, "event: list-updated\ndata: {}\n\n")
                end
            catch e
                # Channel might be closed or broken, handle gracefully
            end
        end
    end
end

function close_sse_clients()
    lock(SSE_LOCK) do
        for chan in SSE_CLIENTS
            try
                close(chan)
            catch e
                # Ignore errors during closing
            end
        end
        empty!(SSE_CLIENTS)
    end
end


# Helper to extract cookie from request
function get_cookie(req::HTTP.Request, name::String)
    cookie_header = HTTP.header(req, "Cookie", "")
    if isempty(cookie_header)
        return nothing
    end
    parts = split(cookie_header, ";")
    for part in parts
        trimmed = strip(part)
        if startswith(trimmed, name * "=")
            split_parts = split(trimmed, "=")
            if length(split_parts) >= 2
                return String(split_parts[2])
            end
        end
    end
    return nothing
end

# Authenticate current request
function get_authenticated_user(req::HTTP.Request)
    token = get_cookie(req, "session_id")
    if token === nothing
        return nothing
    end
    username = Base.get(SESSIONS, token, nothing)
    if username !== nothing
        return username
    end
    # Fallback to database
    rows = db_query("SELECT username FROM sessions WHERE token = ?;", (token,))
    if !isempty(rows)
        username = rows[1]["username"]
        SESSIONS[token] = username
        return username
    end
    return nothing
end

# Check if user can access list
function has_list_access(username::String, list_id::Int)
    rows = db_query("SELECT owner, is_shared FROM lists WHERE id = ?", (list_id,))
    if isempty(rows)
        return false
    end
    list = rows[1]
    return list["is_shared"] == 1 || list["owner"] == username
end

# Fetch lists structured with nested items (using String keys)
function get_lists_for_user(username::String)
    lists = db_query("SELECT * FROM lists WHERE is_shared = 1 OR owner = ? ORDER BY id DESC", (username,))
    if isempty(lists)
        return Dict{String, Any}[]
    end
    
    list_ids = [l["id"] for l in lists]
    placeholders = join(repeat(["?"], length(list_ids)), ", ")
    items = db_query("SELECT * FROM items WHERE list_id IN ($placeholders) ORDER BY position ASC, id ASC", Tuple(list_ids))
    
    list_map = Dict{Int, Dict{String, Any}}()
    for l in lists
        l["is_shared"] = l["is_shared"] == 1
        l["show_hidden"] = l["show_hidden"] == 1
        l["items"] = []
        list_map[l["id"]] = l
    end
    
    for item in items
        item["is_done"] = item["is_done"] == 1
        list_id = item["list_id"]
        if haskey(list_map, list_id)
            list_obj = list_map[list_id]
            
            is_item_hidden = false
            if item["is_done"] && item["checked_at"] !== nothing
                try
                    checked_at = DateTime(item["checked_at"], "yyyy-mm-dd HH:MM:SS")
                    if Dates.now(Dates.UTC) - checked_at >= Dates.Hour(24)
                        is_item_hidden = true
                    end
                catch e
                    @error "Error parsing checked_at" exception=e
                end
            end
            
            item["is_hidden"] = is_item_hidden
            
            # If item is hidden and show_hidden is false, do not include it in the displayed items
            if is_item_hidden && !list_obj["show_hidden"]
                continue
            end
            
            push!(list_obj["items"], item)
        end
    end
    
    return lists
end

function render_mustache(template_file::String, context::Dict{String, Any}=Dict{String, Any}())
    context["base_path"] = get_base_path()
    template_path = joinpath(PROJECT_ROOT, "templates", template_file)
    return Mustache.render(read(template_path, String), context)
end

# Renders the dashboard lists fragment
function render_lists_fragment(username::String)
    lists = get_lists_for_user(username)
    suggestions = db_query("SELECT name FROM autosuggestions ORDER BY name COLLATE NOCASE ASC;")
    context = Dict{String, Any}(
        "username" => username,
        "lists" => lists,
        "fragment" => true,
        "suggestions" => suggestions
    )
    return render_mustache("dashboard.mustache", context)
end

# Check if request is from HTMX
function is_htmx(req::HTTP.Request)
    return !isempty(HTTP.header(req, "HX-Request", ""))
end

# Response Helper for Unauthorized HTMX vs Full Page
function handle_unauthorized(req::HTTP.Request)
    bp = get_base_path()
    if is_htmx(req)
        return HTTP.Response(200, ["HX-Redirect" => bp * "/login"], body="")
    else
        return HTTP.Response(303, ["Location" => bp * "/login"], body="")
    end
end

# Oxygen Routes Setup

@get "/manifest.json" function(req::HTTP.Request)
    html_content = render_mustache("manifest.mustache")
    return HTTP.Response(200, ["Content-Type" => "application/manifest+json; charset=utf-8"], body=html_content)
end

@get "/sw.js" function(req::HTTP.Request)
    html_content = render_mustache("sw.mustache")
    return HTTP.Response(200, ["Content-Type" => "application/javascript; charset=utf-8"], body=html_content)
end

@get "/icons/{filename}" function(req::HTTP.Request, filename::String)
    if occursin("..", filename) || occursin("/", filename) || occursin("\\", filename)
        return HTTP.Response(400, "Invalid filename")
    end
    icon_path = joinpath(PROJECT_ROOT, "templates", "icons", filename)
    if !isfile(icon_path)
        return HTTP.Response(404, "Icon Not Found")
    end
    mime_type = "image/png"
    if endswith(filename, ".svg")
        mime_type = "image/svg+xml"
    end
    return HTTP.Response(200, ["Content-Type" => mime_type], body=read(icon_path))
end

@get "/" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    return HTTP.Response(303, ["Location" => get_base_path() * "/lists"])
end

@get "/login" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username !== nothing
        return HTTP.Response(303, ["Location" => get_base_path() * "/lists"])
    end
    html_content = render_mustache("login.mustache")
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/login" function(req::HTTP.Request)
    data = formdata(req)
    username = strip(Base.get(data, "username", ""))
    password = Base.get(data, "password", "")
    
    rows = db_query("SELECT password_hash, salt FROM users WHERE username = ?;", (username,))
    authenticated = false
    if !isempty(rows)
        user = rows[1]
        hash = hash_password(password, user["salt"])
        if hash == user["password_hash"]
            authenticated = true
        end
    end
    
    bp = get_base_path()
    cookie_path = isempty(bp) ? "/" : bp
    if authenticated
        # Generate and save session token
        token = randstring(32)
        SESSIONS[token] = username
        # Persist session in SQLite
        db_execute("INSERT OR REPLACE INTO sessions (token, username) VALUES (?, ?);", (token, username))
        return HTTP.Response(303, [
            "Location" => bp * "/lists",
            "Set-Cookie" => "session_id=$token; Path=$cookie_path; HttpOnly; SameSite=Lax; Max-Age=2592000"
        ])
    else
        html_content = render_mustache("login.mustache", Dict{String, Any}("error" => "Invalid username or password"))
        return HTTP.Response(401, ["Content-Type" => "text/html"], body=html_content)
    end
end

@get "/logout" function(req::HTTP.Request)
    token = get_cookie(req, "session_id")
    if token !== nothing
        delete!(SESSIONS, token)
        db_execute("DELETE FROM sessions WHERE token = ?;", (token,))
    end
    bp = get_base_path()
    cookie_path = isempty(bp) ? "/" : bp
    return HTTP.Response(303, [
        "Location" => bp * "/login",
        "Set-Cookie" => "session_id=; Path=$cookie_path; HttpOnly; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    ])
end

@get "/lists" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    lists = get_lists_for_user(username)
    suggestions = db_query("SELECT name FROM autosuggestions ORDER BY name COLLATE NOCASE ASC;")
    context = Dict{String, Any}(
        "username" => username,
        "lists" => lists,
        "fragment" => false,
        "suggestions" => suggestions
    )
    html_content = render_mustache("dashboard.mustache", context)
    
    bp = get_base_path()
    cookie_path = isempty(bp) ? "/" : bp
    # Extend/refresh the session cookie lifetime (sliding expiration) on every successful visit
    token = get_cookie(req, "session_id")
    return HTTP.Response(200, [
        "Content-Type" => "text/html",
        "Set-Cookie" => "session_id=$token; Path=$cookie_path; HttpOnly; SameSite=Lax; Max-Age=2592000"
    ], body=html_content)
end

@get "/lists/content" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    html_content = render_lists_fragment(username)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@get "/lists/events" function(stream::HTTP.Stream)
    req = stream.message
    username = get_authenticated_user(req)
    if username === nothing
        HTTP.setstatus(stream, 401)
        HTTP.setheader(stream, "Content-Type" => "text/html")
        HTTP.startwrite(stream)
        write(stream, "Unauthorized")
        return
    end
    
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.setheader(stream, "Connection" => "keep-alive")
    HTTP.startwrite(stream)
    
    client_chan = Channel{String}(32)
    register_sse_client(client_chan)
    try
        write(stream, ": ok\n\n")
        while isopen(stream) && isopen(client_chan)
            msg = take!(client_chan)
            if isopen(stream)
                write(stream, msg)
            end
        end
    catch e
        # Client disconnected
    finally
        unregister_sse_client(client_chan)
    end
end

@post "/lists" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    data = formdata(req)
    name = strip(Base.get(data, "name", ""))
    # Default is private (0), shared is (1)
    is_shared = Base.get(data, "is_shared", "0") == "1" ? 1 : 0
    
    if !isempty(name)
        db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", (name, username, is_shared))
        notify_sse_clients()
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@get "/lists/{id}/edit" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    rows = db_query("SELECT owner, name, is_shared FROM lists WHERE id = ?;", (list_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    
    is_owner = rows[1]["owner"] == username
    is_shared = rows[1]["is_shared"] == 1
    
    context = Dict{String, Any}(
        "id" => list_id,
        "name" => rows[1]["name"],
        "is_owner" => is_owner,
        "is_shared" => is_shared
    )
    html_content = render_mustache("edit_list_modal.mustache", context)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/lists/{id}/edit" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    rows = db_query("SELECT owner FROM lists WHERE id = ?;", (list_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    is_owner = rows[1]["owner"] == username
    
    data = formdata(req)
    name = strip(Base.get(data, "name", ""))
    
    if !isempty(name)
        if is_owner
            is_shared = Base.get(data, "is_shared", "0") == "1" ? 1 : 0
            
            # Retroactively add items if changing from private to shared
            old_is_shared_row = db_query("SELECT is_shared FROM lists WHERE id = ?;", (list_id,))
            was_shared = !isempty(old_is_shared_row) && old_is_shared_row[1]["is_shared"] == 1
            
            db_execute("UPDATE lists SET name = ?, is_shared = ? WHERE id = ?;", (name, is_shared, list_id))
            
            if is_shared == 1 && !was_shared
                # Add existing items of this list to autosuggestions
                items = db_query("SELECT name FROM items WHERE list_id = ?;", (list_id,))
                for item in items
                    db_execute("INSERT OR IGNORE INTO autosuggestions (name) VALUES (?);", (item["name"],))
                end
            end
        else
            db_execute("UPDATE lists SET name = ? WHERE id = ?;", (name, list_id))
        end
        notify_sse_clients()
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@get "/lists/{id}/delete" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    rows = db_query("SELECT name FROM lists WHERE id = ?;", (list_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    
    context = Dict{String, Any}(
        "id" => list_id,
        "name" => rows[1]["name"]
    )
    html_content = render_mustache("delete_list_modal.mustache", context)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@delete "/lists/{id}" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    db_execute("DELETE FROM lists WHERE id = ?;", (list_id,))
    notify_sse_clients()
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@post "/lists/{id}/items" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    data = formdata(req)
    name = strip(Base.get(data, "name", ""))
    if !isempty(name)
        r = db_query("SELECT MAX(position) as m FROM items WHERE list_id = ?;", (list_id,))
        max_pos = isempty(r) || r[1]["m"] === nothing ? 0 : r[1]["m"]
        db_execute("INSERT INTO items (list_id, name, is_done, position) VALUES (?, ?, 0, ?);", (list_id, name, max_pos + 1))
        
        # Check if list is shared before adding to autosuggestions
        is_shared_row = db_query("SELECT is_shared FROM lists WHERE id = ?;", (list_id,))
        is_shared = !isempty(is_shared_row) && is_shared_row[1]["is_shared"] == 1
        if is_shared
            db_execute("INSERT OR IGNORE INTO autosuggestions (name) VALUES (?);", (name,))
        end
        
        notify_sse_clients()
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@post "/lists/{id}/reorder" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    data = formdata(req)
    ids_str = Base.get(data, "ids", "")
    if !isempty(ids_str)
        id_list = [parse(Int, s) for s in split(ids_str, ",")]
        for (pos, item_id) in enumerate(id_list)
            db_execute("UPDATE items SET position = ? WHERE id = ? AND list_id = ?;", (pos, item_id, list_id))
        end
        notify_sse_clients()
    end
    
    return HTTP.Response(200, "OK")
end

@post "/items/{item_id}/toggle" function(req::HTTP.Request, item_id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    it_id = parse(Int, item_id)
    # Check parent list access
    rows = db_query("SELECT list_id, is_done FROM items WHERE id = ?;", (it_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    item = rows[1]
    list_id = item["list_id"]
    
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    new_done = item["is_done"] == 1 ? 0 : 1
    checked_at = new_done == 1 ? Dates.format(Dates.now(Dates.UTC), "yyyy-mm-dd HH:MM:SS") : nothing
    db_execute("UPDATE items SET is_done = ?, checked_at = ? WHERE id = ?;", (new_done, checked_at, it_id))
    notify_sse_clients()
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@post "/lists/{id}/toggle_hidden" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    list_id = parse(Int, id)
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    rows = db_query("SELECT show_hidden FROM lists WHERE id = ?;", (list_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    new_show = rows[1]["show_hidden"] == 1 ? 0 : 1
    db_execute("UPDATE lists SET show_hidden = ? WHERE id = ?;", (new_show, list_id))
    notify_sse_clients()
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@get "/items/{item_id}/edit" function(req::HTTP.Request, item_id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    it_id = parse(Int, item_id)
    rows = db_query("SELECT list_id, name FROM items WHERE id = ?;", (it_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    item = rows[1]
    list_id = item["list_id"]
    
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    context = Dict{String, Any}(
        "id" => it_id,
        "name" => item["name"]
    )
    html_content = render_mustache("edit_item_modal.mustache", context)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/items/{item_id}/edit" function(req::HTTP.Request, item_id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    it_id = parse(Int, item_id)
    rows = db_query("SELECT list_id FROM items WHERE id = ?;", (it_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    list_id = rows[1]["list_id"]
    
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    data = formdata(req)
    name = strip(Base.get(data, "name", ""))
    if !isempty(name)
        db_execute("UPDATE items SET name = ? WHERE id = ?;", (name, it_id))
        notify_sse_clients()
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@delete "/items/{item_id}" function(req::HTTP.Request, item_id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    it_id = parse(Int, item_id)
    rows = db_query("SELECT list_id FROM items WHERE id = ?;", (it_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    list_id = rows[1]["list_id"]
    
    if !has_list_access(username, list_id)
        return HTTP.Response(403, "Forbidden")
    end
    
    db_execute("DELETE FROM items WHERE id = ?;", (it_id,))
    notify_sse_clients()
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

@get "/admin" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    is_admin = !isempty(user_rows) && user_rows[1]["role"] == "admin"
    
    suggestions = db_query("SELECT * FROM autosuggestions ORDER BY name COLLATE NOCASE ASC;")
    
    users_list = []
    if is_admin
        users_list = db_query("SELECT id, username, role FROM users ORDER BY username COLLATE NOCASE ASC;")
        for u in users_list
            u["is_not_self"] = u["username"] != username
            u["is_admin_role"] = u["role"] == "admin"
        end
    end
    
    uri = HTTP.URI(req.target)
    query_params = HTTP.queryparams(uri)
    created_link = Base.get(query_params, "created_link", nothing)
    error_msg = Base.get(query_params, "error", nothing)
    success_msg = Base.get(query_params, "success", nothing)
    
    context = Dict{String, Any}(
        "username" => username,
        "is_admin" => is_admin,
        "suggestions" => suggestions,
        "users" => users_list,
        "created_link" => created_link,
        "error" => error_msg,
        "success" => success_msg
    )
    html_content = render_mustache("admin.mustache", context)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/admin/suggestions" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    data = formdata(req)
    name = strip(Base.get(data, "name", ""))
    if !isempty(name)
        db_execute("INSERT OR IGNORE INTO autosuggestions (name) VALUES (?);", (name,))
    end
    
    bp = get_base_path()
    return HTTP.Response(303, ["Location" => bp * "/admin"])
end

@delete "/admin/suggestions/{id}" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    s_id = parse(Int, id)
    db_execute("DELETE FROM autosuggestions WHERE id = ?;", (s_id,))
    
    bp = get_base_path()
    if is_htmx(req)
        return HTTP.Response(200, ["HX-Redirect" => bp * "/admin"], body="")
    else
        return HTTP.Response(303, ["Location" => bp * "/admin"])
    end
end

@post "/admin/profile/username" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    data = formdata(req)
    new_username = strip(Base.get(data, "username", ""))
    bp = get_base_path()
    if isempty(new_username)
        return HTTP.Response(303, ["Location" => bp * "/admin?error=Username cannot be empty"])
    end
    
    if new_username == username
        return HTTP.Response(303, ["Location" => bp * "/admin"])
    end
    
    # Check if new username is already taken
    exist = db_query("SELECT id FROM users WHERE username = ?;", (new_username,))
    if !isempty(exist)
        return HTTP.Response(303, ["Location" => bp * "/admin?error=Username already taken"])
    end
    
    # Update users table
    db_execute("UPDATE users SET username = ? WHERE username = ?;", (new_username, username))
    
    # Update all lists owned by this user
    db_execute("UPDATE lists SET owner = ? WHERE owner = ?;", (new_username, username))
    
    # Update active sessions in memory and DB
    for (t, u) in collect(SESSIONS)
        if u == username
            SESSIONS[t] = new_username
        end
    end
    db_execute("UPDATE sessions SET username = ? WHERE username = ?;", (new_username, username))
    
    return HTTP.Response(303, ["Location" => bp * "/admin?success=Username updated successfully"])
end

@post "/admin/profile/password" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    data = formdata(req)
    new_password = Base.get(data, "password", "")
    bp = get_base_path()
    if isempty(new_password)
        return HTTP.Response(303, ["Location" => bp * "/admin?error=Password cannot be empty"])
    end
    
    new_salt = string(uuid4())
    new_hash = hash_password(new_password, new_salt)
    
    db_execute("UPDATE users SET password_hash = ?, salt = ? WHERE username = ?;", (new_hash, new_salt, username))
    return HTTP.Response(303, ["Location" => bp * "/admin?success=Password updated successfully"])
end

@post "/admin/users/create" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    data = formdata(req)
    new_user = strip(Base.get(data, "username", ""))
    role = strip(Base.get(data, "role", "user"))
    bp = get_base_path()
    if isempty(new_user)
        return HTTP.Response(303, ["Location" => bp * "/admin?error=Username cannot be empty"])
    end
    
    # Check if username exists
    exist = db_query("SELECT id FROM users WHERE username = ?;", (new_user,))
    if !isempty(exist)
        return HTTP.Response(303, ["Location" => bp * "/admin?error=User already exists"])
    end
    
    # Insert user with blank password first
    db_execute("INSERT INTO users (username, password_hash, salt, role) VALUES (?, '', '', ?);", (new_user, role))
    
    # Create a reset password link/token
    token = string(uuid4())
    db_execute("INSERT INTO password_resets (token, username) VALUES (?, ?);", (token, new_user))
    
    if !isassigned(CONFIG)
        load_config()
    end
    server_cfg = Base.get(CONFIG[], "server", Dict{String, Any}())
    cfg_host = Base.get(server_cfg, "host", "localhost")
    cfg_port = Base.get(server_cfg, "port", 8080)
    host_part = (cfg_port == 80 || cfg_port == 443) ? cfg_host : "$cfg_host:$cfg_port"
    
    proto = HTTP.header(req, "X-Forwarded-Proto", cfg_port == 443 ? "https" : "http")
    reset_link = "$proto://$host_part$bp/reset-password?token=$token"
    
    return HTTP.Response(303, ["Location" => bp * "/admin?created_link=$(HTTP.escapeuri(reset_link))"])
end

@get "/admin/users/{id}/edit" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    target_id = parse(Int, id)
    target_rows = db_query("SELECT id, username, role FROM users WHERE id = ?;", (target_id,))
    if isempty(target_rows)
        return HTTP.Response(404, "Not Found")
    end
    
    context = Dict{String, Any}(
        "id" => target_id,
        "username" => target_rows[1]["username"],
        "is_admin_role" => target_rows[1]["role"] == "admin"
    )
    html_content = render_mustache("edit_user_modal.mustache", context)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/admin/users/{id}/edit" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    target_id = parse(Int, id)
    target_rows = db_query("SELECT username FROM users WHERE id = ?;", (target_id,))
    if isempty(target_rows)
        return HTTP.Response(404, "User Not Found")
    end
    target_username = target_rows[1]["username"]
    
    data = formdata(req)
    new_username = strip(Base.get(data, "username", ""))
    role = strip(Base.get(data, "role", "user"))
    bp = get_base_path()
    
    if isempty(new_username)
        return HTTP.Response(303, ["Location" => bp * "/admin?error=Username cannot be empty"])
    end
    
    if new_username != target_username
        exist = db_query("SELECT id FROM users WHERE username = ?;", (new_username,))
        if !isempty(exist)
            return HTTP.Response(303, ["Location" => bp * "/admin?error=Username already taken"])
        end
    end
    
    if target_username == username && role != "admin"
        return HTTP.Response(303, ["Location" => bp * "/admin?error=Cannot demote yourself from admin"])
    end
    
    db_execute("UPDATE users SET username = ?, role = ? WHERE id = ?;", (new_username, role, target_id))
    
    if new_username != target_username
        db_execute("UPDATE lists SET owner = ? WHERE owner = ?;", (new_username, target_username))
        for (t, u) in collect(SESSIONS)
            if u == target_username
                SESSIONS[t] = new_username
            end
        end
        db_execute("UPDATE sessions SET username = ? WHERE username = ?;", (new_username, target_username))
    end
    
    return HTTP.Response(303, ["Location" => bp * "/admin?success=User updated successfully"])
end

@delete "/admin/users/{id}" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    target_id = parse(Int, id)
    target_rows = db_query("SELECT username FROM users WHERE id = ?;", (target_id,))
    if isempty(target_rows)
        return HTTP.Response(404, "User Not Found")
    end
    target_username = target_rows[1]["username"]
    bp = get_base_path()
    
    if target_username == username
        if is_htmx(req)
            return HTTP.Response(200, ["HX-Redirect" => bp * "/admin?error=Cannot delete yourself"], body="")
        else
            return HTTP.Response(303, ["Location" => bp * "/admin?error=Cannot delete yourself"])
        end
    end
    
    db_execute("DELETE FROM users WHERE id = ?;", (target_id,))
    db_execute("DELETE FROM password_resets WHERE username = ?;", (target_username,))
    db_execute("DELETE FROM sessions WHERE username = ?;", (target_username,))
    for (t, u) in collect(SESSIONS)
        if u == target_username
            delete!(SESSIONS, t)
        end
    end
    
    if is_htmx(req)
        return HTTP.Response(200, ["HX-Redirect" => bp * "/admin?success=User deleted"], body="")
    else
        return HTTP.Response(303, ["Location" => bp * "/admin?success=User deleted"])
    end
end

@post "/admin/users/{id}/reset" function(req::HTTP.Request, id::String)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    user_rows = db_query("SELECT role FROM users WHERE username = ?;", (username,))
    if isempty(user_rows) || user_rows[1]["role"] != "admin"
        return HTTP.Response(403, "Forbidden")
    end
    
    target_id = parse(Int, id)
    target_rows = db_query("SELECT username FROM users WHERE id = ?;", (target_id,))
    if isempty(target_rows)
        return HTTP.Response(404, "User Not Found")
    end
    target_username = target_rows[1]["username"]
    
    token = string(uuid4())
    db_execute("INSERT OR REPLACE INTO password_resets (token, username) VALUES (?, ?);", (token, target_username))
    
    bp = get_base_path()
    if !isassigned(CONFIG)
        load_config()
    end
    server_cfg = Base.get(CONFIG[], "server", Dict{String, Any}())
    cfg_host = Base.get(server_cfg, "host", "localhost")
    cfg_port = Base.get(server_cfg, "port", 8080)
    host_part = (cfg_port == 80 || cfg_port == 443) ? cfg_host : "$cfg_host:$cfg_port"
    
    proto = HTTP.header(req, "X-Forwarded-Proto", cfg_port == 443 ? "https" : "http")
    reset_link = "$proto://$host_part$bp/reset-password?token=$token"
    
    return HTTP.Response(303, ["Location" => bp * "/admin?created_link=$(HTTP.escapeuri(reset_link))"])
end

@get "/reset-password" function(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    query_params = HTTP.queryparams(uri)
    token = Base.get(query_params, "token", "")
    
    if isempty(token)
        return HTTP.Response(400, "Missing reset token")
    end
    
    rows = db_query("SELECT username FROM password_resets WHERE token = ?;", (token,))
    if isempty(rows)
        return HTTP.Response(400, "Invalid or expired reset token")
    end
    
    html_content = render_mustache("reset_password.mustache", Dict{String, Any}("token" => token, "username" => rows[1]["username"]))
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/reset-password" function(req::HTTP.Request)
    data = formdata(req)
    token = Base.get(data, "token", "")
    password = Base.get(data, "password", "")
    
    if isempty(token) || isempty(password)
        return HTTP.Response(400, "Missing token or password")
    end
    
    rows = db_query("SELECT username FROM password_resets WHERE token = ?;", (token,))
    if isempty(rows)
        return HTTP.Response(400, "Invalid or expired reset token")
    end
    target_username = rows[1]["username"]
    
    new_salt = string(uuid4())
    new_hash = hash_password(password, new_salt)
    
    db_execute("UPDATE users SET password_hash = ?, salt = ? WHERE username = ?;", (new_hash, new_salt, target_username))
    db_execute("DELETE FROM password_resets WHERE token = ?;", (token,))
    
    html_content = render_mustache("login.mustache", Dict{String, Any}("success" => "Password set successfully! You can now log in."))
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

function start_server(port::Integer, async::Bool=false)
    start_server("0.0.0.0", port, async)
end

function start_server(host::String="0.0.0.0", port::Integer=8080, async::Bool=false)
    serve(host=host, port=port, async=async, middleware=[prefix_stripper_middleware])
end

function stop_server()
    close_sse_clients()
    terminate()
end

function __init__()
    # Initialize DB with environment defaults or defaults relative to package root
    if !isassigned(DB_CONN)
        try
            init_db_and_users()
        catch e
            @warn "Failed to auto-initialize database during module initialization: $e"
        end
    end
end

function main(args)
    load_config()
    server_cfg = Base.get(CONFIG[], "server", Dict{String, Any}())
    port = Base.get(server_cfg, "port", 8080)
    host = Base.get(server_cfg, "host", "0.0.0.0")
    db_path = nothing
    
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "-p" || arg == "--port"
            if i + 1 <= length(args)
                port = parse(Int, args[i+1])
                i += 2
            else
                println("Error: Missing port value")
                return 1
            end
        elseif arg == "-o" || arg == "--host"
            if i + 1 <= length(args)
                host = args[i+1]
                i += 2
            else
                println("Error: Missing host value")
                return 1
            end
        elseif arg == "-d" || arg == "--db"
            if i + 1 <= length(args)
                db_path = args[i+1]
                i += 2
            else
                println("Error: Missing database path")
                return 1
            end
        elseif arg == "-h" || arg == "--help"
            println("SyncList - Collaborative list app")
            println("Usage: synclist [options]")
            println("Options:")
            println("  -p, --port <port>       Port to listen on (default: 8080)")
            println("  -o, --host <host>       Host to bind to (default: 0.0.0.0)")
            println("  -d, --db <path>         Path to SQLite database file")
            println("  -h, --help              Show this help message")
            return 0
        else
            println("Unknown option: ", arg)
            return 1
        end
    end
    
    # Initialize DB
    init_db_and_users(db_path)
    
    println("Starting SyncList server on ", host, ":", port)
    start_server(host, port, false)
    return 0
end

Base.@main

end # module
