module SyncList

using Oxygen
@oxidize
using Mustache
using SQLite
using TOML
using Dates
using Random

import HTTP

# Database and Lock initialization
const DB_LOCK = ReentrantLock()
const PROJECT_ROOT = dirname(@__DIR__)

const DB_CONN = let
    db = SQLite.DB(joinpath(PROJECT_ROOT, "synclist.db"))
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

    # Create sessions table
    SQLite.execute(db, """
    CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        username TEXT NOT NULL
    );
    """)
    db
end

# Database Query Helpers (returns Dict with String keys for Mustache compatibility)
function db_query(sql::String, params=())
    lock(DB_LOCK) do
        cursor = SQLite.DBInterface.execute(DB_CONN, sql, params)
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
        SQLite.DBInterface.execute(DB_CONN, sql, params)
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

# Load Users from TOML
const USERS_FILE = joinpath(PROJECT_ROOT, "users.toml")
function load_users()
    if !isfile(USERS_FILE)
        return Dict{String, Any}()
    end
    try
        data = TOML.parsefile(USERS_FILE)
        return Base.get(data, "users", Dict{String, Any}())
    catch e
        @error "Error parsing users.toml" exception=e
        return Dict{String, Any}()
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
    items = db_query("SELECT * FROM items WHERE list_id IN ($placeholders) ORDER BY id ASC", Tuple(list_ids))
    
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

# Renders the dashboard lists fragment
function render_lists_fragment(username::String)
    lists = get_lists_for_user(username)
    context = Dict{String, Any}(
        "username" => username,
        "lists" => lists,
        "fragment" => true
    )
    template_path = joinpath(PROJECT_ROOT, "templates", "dashboard.mustache")
    return Mustache.render(read(template_path, String), context)
end

# Check if request is from HTMX
function is_htmx(req::HTTP.Request)
    return !isempty(HTTP.header(req, "HX-Request", ""))
end

# Response Helper for Unauthorized HTMX vs Full Page
function handle_unauthorized(req::HTTP.Request)
    if is_htmx(req)
        return HTTP.Response(200, ["HX-Redirect" => "/login"], body="")
    else
        return HTTP.Response(303, ["Location" => "/login"], body="")
    end
end

# Oxygen Routes Setup

@get "/" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    return HTTP.Response(303, ["Location" => "/lists"])
end

@get "/login" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username !== nothing
        return HTTP.Response(303, ["Location" => "/lists"])
    end
    template_path = joinpath(PROJECT_ROOT, "templates", "login.mustache")
    html_content = Mustache.render(read(template_path, String), Dict{String, Any}())
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/login" function(req::HTTP.Request)
    data = formdata(req)
    username = strip(Base.get(data, "username", ""))
    password = Base.get(data, "password", "")
    
    users = load_users()
    if haskey(users, username) && users[username] == password
        # Generate and save session token
        token = randstring(32)
        SESSIONS[token] = username
        # Persist session in SQLite
        db_execute("INSERT OR REPLACE INTO sessions (token, username) VALUES (?, ?);", (token, username))
        return HTTP.Response(303, [
            "Location" => "/lists",
            "Set-Cookie" => "session_id=$token; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"
        ])
    else
        template_path = joinpath(PROJECT_ROOT, "templates", "login.mustache")
        html_content = Mustache.render(read(template_path, String), Dict{String, Any}("error" => "Invalid username or password"))
        return HTTP.Response(401, ["Content-Type" => "text/html"], body=html_content)
    end
end

@get "/logout" function(req::HTTP.Request)
    token = get_cookie(req, "session_id")
    if token !== nothing
        delete!(SESSIONS, token)
        db_execute("DELETE FROM sessions WHERE token = ?;", (token,))
    end
    return HTTP.Response(303, [
        "Location" => "/login",
        "Set-Cookie" => "session_id=; Path=/; HttpOnly; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    ])
end

@get "/lists" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    lists = get_lists_for_user(username)
    context = Dict{String, Any}(
        "username" => username,
        "lists" => lists,
        "fragment" => false
    )
    template_path = joinpath(PROJECT_ROOT, "templates", "dashboard.mustache")
    html_content = Mustache.render(read(template_path, String), context)
    
    # Extend/refresh the session cookie lifetime (sliding expiration) on every successful visit
    token = get_cookie(req, "session_id")
    return HTTP.Response(200, [
        "Content-Type" => "text/html",
        "Set-Cookie" => "session_id=$token; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"
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
    
    rows = db_query("SELECT name FROM lists WHERE id = ?;", (list_id,))
    if isempty(rows)
        return HTTP.Response(404, "Not Found")
    end
    
    context = Dict{String, Any}(
        "id" => list_id,
        "name" => rows[1]["name"]
    )
    template_path = joinpath(PROJECT_ROOT, "templates", "edit_list_modal.mustache")
    html_content = Mustache.render(read(template_path, String), context)
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
    
    data = formdata(req)
    name = strip(Base.get(data, "name", ""))
    if !isempty(name)
        db_execute("UPDATE lists SET name = ? WHERE id = ?;", (name, list_id))
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
    template_path = joinpath(PROJECT_ROOT, "templates", "delete_list_modal.mustache")
    html_content = Mustache.render(read(template_path, String), context)
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
        db_execute("INSERT INTO items (list_id, name, is_done) VALUES (?, ?, 0);", (list_id, name))
        notify_sse_clients()
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
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
    template_path = joinpath(PROJECT_ROOT, "templates", "edit_item_modal.mustache")
    html_content = Mustache.render(read(template_path, String), context)
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

function start_server(port=8080, async=false)
    serve(host="0.0.0.0", port=port, async=async)
end

function stop_server()
    terminate()
end

end # module
