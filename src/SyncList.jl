module SyncList

using Oxygen
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
        is_shared INTEGER DEFAULT 0
    );
    """)
    
    # Create items table
    SQLite.execute(db, """
    CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        list_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        is_done INTEGER DEFAULT 0,
        FOREIGN KEY(list_id) REFERENCES lists(id) ON DELETE CASCADE
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

# Load Users from TOML
const USERS_FILE = joinpath(PROJECT_ROOT, "users.toml")
function load_users()
    if !isfile(USERS_FILE)
        return Dict{String, Any}()
    end
    try
        data = TOML.parsefile(USERS_FILE)
        return get(data, "users", Dict{String, Any}())
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
    return get(SESSIONS, token, nothing)
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
        l["items"] = []
        list_map[l["id"]] = l
    end
    
    for item in items
        item["is_done"] = item["is_done"] == 1
        list_id = item["list_id"]
        if haskey(list_map, list_id)
            push!(list_map[list_id]["items"], item)
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
    username = strip(get(data, "username", ""))
    password = get(data, "password", "")
    
    users = load_users()
    if haskey(users, username) && users[username] == password
        # Generate and save session token
        token = randstring(32)
        SESSIONS[token] = username
        return HTTP.Response(303, [
            "Location" => "/lists",
            "Set-Cookie" => "session_id=$token; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400"
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
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@get "/lists/content" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    html_content = render_lists_fragment(username)
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=html_content)
end

@post "/lists" function(req::HTTP.Request)
    username = get_authenticated_user(req)
    if username === nothing
        return handle_unauthorized(req)
    end
    
    data = formdata(req)
    name = strip(get(data, "name", ""))
    # Default is private (0), shared is (1)
    is_shared = get(data, "is_shared", "0") == "1" ? 1 : 0
    
    if !isempty(name)
        db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", (name, username, is_shared))
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
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
    name = strip(get(data, "name", ""))
    if !isempty(name)
        db_execute("UPDATE lists SET name = ? WHERE id = ?;", (name, list_id))
    end
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
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
    name = strip(get(data, "name", ""))
    if !isempty(name)
        db_execute("INSERT INTO items (list_id, name, is_done) VALUES (?, ?, 0);", (list_id, name))
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
    db_execute("UPDATE items SET is_done = ? WHERE id = ?;", (new_done, it_id))
    
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
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
    name = strip(get(data, "name", ""))
    if !isempty(name)
        db_execute("UPDATE items SET name = ? WHERE id = ?;", (name, it_id))
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
    return HTTP.Response(200, ["Content-Type" => "text/html"], body=render_lists_fragment(username))
end

function start_server(port=8080)
    serve(port=port)
end

end # module
