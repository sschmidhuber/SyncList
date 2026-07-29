using Test

# Include backend and verify compilation
include("../src/SyncList.jl")

@testset "SyncList Logic Tests" begin
    # Reset tables and auto-increment sequences
    SyncList.db_execute("DELETE FROM items;")
    SyncList.db_execute("DELETE FROM lists;")
    try
        SyncList.db_execute("DELETE FROM sqlite_sequence WHERE name='lists';")
        SyncList.db_execute("DELETE FROM sqlite_sequence WHERE name='items';")
    catch
        # sqlite_sequence might not exist yet if AUTOINCREMENT has not run
    end

    # 1. Test Load Users
    users = SyncList.load_users()
    @test haskey(users, "stefan")
    @test users["stefan"] == "julia123"

    # 2. Test List creation and retrieval
    SyncList.db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", ("Private List", "stefan", 0))
    SyncList.db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", ("Shared List", "alice", 1))

    # Retrieve generated IDs dynamically
    inserted_lists = SyncList.db_query("SELECT id, name FROM lists;")
    priv_id = filter(l -> l["name"] == "Private List", inserted_lists)[1]["id"]
    shared_id = filter(l -> l["name"] == "Shared List", inserted_lists)[1]["id"]

    # Check access control
    @test SyncList.has_list_access("stefan", priv_id) == true
    @test SyncList.has_list_access("alice", priv_id) == false
    @test SyncList.has_list_access("bob", shared_id) == true

    # 3. Test list items nested retrieval
    lists_stefan = SyncList.get_lists_for_user("stefan")
    @test length(lists_stefan) == 2
    
    priv_list = filter(l -> l["id"] == priv_id, lists_stefan)[1]
    @test priv_list["is_shared"] == false

    # Add items to Private List
    SyncList.db_execute("INSERT INTO items (list_id, name, is_done) VALUES (?, ?, 0);", (priv_id, "Buy Milk"))
    SyncList.db_execute("INSERT INTO items (list_id, name, is_done) VALUES (?, ?, 1);", (priv_id, "Buy Eggs"))

    # Fetch again and check items
    lists_stefan = SyncList.get_lists_for_user("stefan")
    priv_list = filter(l -> l["id"] == priv_id, lists_stefan)[1]
    @test length(priv_list["items"]) == 2
    @test priv_list["items"][1]["name"] == "Buy Milk"
    @test priv_list["items"][1]["is_done"] == false
    @test priv_list["items"][2]["name"] == "Buy Eggs"
    @test priv_list["items"][2]["is_done"] == true
end

@testset "Checked Items Auto-Hiding and Show Hidden Option" begin
    # Clean tables
    SyncList.db_execute("DELETE FROM items;")
    SyncList.db_execute("DELETE FROM lists;")

    # 1. Create a list
    SyncList.db_execute("INSERT INTO lists (name, owner, is_shared, show_hidden) VALUES (?, ?, ?, ?);", ("My List", "stefan", 0, 0))
    lists = SyncList.get_lists_for_user("stefan")
    @test length(lists) == 1
    list_id = lists[1]["id"]
    @test lists[1]["show_hidden"] == false

    # 2. Insert items
    # - "Active Item" (not done)
    # - "Recently Checked" (done, checked 1 hour ago)
    # - "Old Checked" (done, checked 25 hours ago)
    # - "Old Checked but Visible" (done, checked 30 hours ago, but list has show_hidden=true)
    now_utc = SyncList.Dates.now(SyncList.Dates.UTC)
    recent_checked_str = SyncList.Dates.format(now_utc - SyncList.Dates.Hour(1), "yyyy-mm-dd HH:MM:SS")
    old_checked_str = SyncList.Dates.format(now_utc - SyncList.Dates.Hour(25), "yyyy-mm-dd HH:MM:SS")

    SyncList.db_execute("INSERT INTO items (list_id, name, is_done, checked_at) VALUES (?, ?, ?, ?);", (list_id, "Active Item", 0, nothing))
    SyncList.db_execute("INSERT INTO items (list_id, name, is_done, checked_at) VALUES (?, ?, ?, ?);", (list_id, "Recently Checked", 1, recent_checked_str))
    SyncList.db_execute("INSERT INTO items (list_id, name, is_done, checked_at) VALUES (?, ?, ?, ?);", (list_id, "Old Checked", 1, old_checked_str))

    # Retrieve with show_hidden = false (default)
    lists = SyncList.get_lists_for_user("stefan")
    items = lists[1]["items"]
    # Only "Active Item" and "Recently Checked" should be returned; "Old Checked" is hidden
    @test length(items) == 2
    @test any(i -> i["name"] == "Active Item", items)
    @test any(i -> i["name"] == "Recently Checked", items)
    @test !any(i -> i["name"] == "Old Checked", items)

    # 3. Toggle list's show_hidden to true
    SyncList.db_execute("UPDATE lists SET show_hidden = 1 WHERE id = ?;", (list_id,))
    lists = SyncList.get_lists_for_user("stefan")
    @test lists[1]["show_hidden"] == true
    items = lists[1]["items"]
    # Now all three items should be visible
    @test length(items) == 3
    @test any(i -> i["name"] == "Active Item", items)
    @test any(i -> i["name"] == "Recently Checked", items)
    @test any(i -> i["name"] == "Old Checked", items)

    # 4. Toggle routes testing
    # Simulate a toggle_hidden request
    req = SyncList.HTTP.Request("POST", "/lists/$(list_id)/toggle_hidden")
    # We need to mock session or authenticate. Let's insert a session.
    token = "test_hidden_token"
    SyncList.db_execute("INSERT INTO sessions (token, username) VALUES (?, ?);", (token, "stefan"))
    req.headers = ["Cookie" => "session_id=$(token)"]
    
    res = SyncList.internalrequest(req)
    @test res.status == 200
    
    # After toggling, it should be back to show_hidden = false (0)
    db_list = SyncList.db_query("SELECT show_hidden FROM lists WHERE id = ?;", (list_id,))
    @test db_list[1]["show_hidden"] == 0

    # 5. Toggle item check testing
    # Insert new item, check toggling updates checked_at
    SyncList.db_execute("INSERT INTO items (list_id, name, is_done, checked_at) VALUES (?, ?, 0, ?);", (list_id, "Toggle Item", nothing))
    it_rows = SyncList.db_query("SELECT id FROM items WHERE name = 'Toggle Item';")
    it_id = it_rows[1]["id"]

    # Toggle to done (checked)
    toggle_req = SyncList.HTTP.Request("POST", "/items/$(it_id)/toggle", ["Cookie" => "session_id=$(token)"])
    res = SyncList.internalrequest(toggle_req)
    @test res.status == 200

    item_db = SyncList.db_query("SELECT is_done, checked_at FROM items WHERE id = ?;", (it_id,))[1]
    @test item_db["is_done"] == 1
    @test item_db["checked_at"] !== nothing

    # Toggle back to active (unchecked)
    res = SyncList.internalrequest(toggle_req)
    @test res.status == 200
    item_db2 = SyncList.db_query("SELECT is_done, checked_at FROM items WHERE id = ?;", (it_id,))[1]
    @test item_db2["is_done"] == 0
    @test item_db2["checked_at"] === nothing
end

@testset "Server Restart Route Persistence" begin
    # Simulate stopping the server (which internally calls terminate() and resetstate())
    # Calling the methods on SyncList directly uses the module-local CONTEXT
    SyncList.terminate()
    SyncList.resetstate()

    # Verify if routes are still matched
    # Since we are using @oxidize, our routes are safe in the module-level CONTEXT of SyncList, and will return the expected 303.
    req = SyncList.HTTP.Request("GET", "/")
    res = SyncList.internalrequest(req)
    @test res.status == 303
end

@testset "Persistent Session Verification" begin
    # Clear existing sessions
    SyncList.db_execute("DELETE FROM sessions;")
    empty!(SyncList.SESSIONS)

    # Simulate a login by inserting a session directly
    token = "testtoken12345"
    SyncList.db_execute("INSERT INTO sessions (token, username) VALUES (?, ?);", (token, "stefan"))

    # Create a request with the session cookie
    req = SyncList.HTTP.Request("GET", "/lists", ["Cookie" => "session_id=testtoken12345"])
    
    # get_authenticated_user should fetch from database and cache it
    @test SyncList.get_authenticated_user(req) == "stefan"
    @test haskey(SyncList.SESSIONS, token)
    @test SyncList.SESSIONS[token] == "stefan"

    # Make request to check if it succeeds and refreshes the cookie
    res = SyncList.internalrequest(req)
    @test res.status == 200
    @test any(h -> h.first == "Set-Cookie" && occursin("session_id=testtoken12345", h.second) && occursin("Max-Age=2592000", h.second), res.headers)
end

@testset "Items Reordering and Sorting Persistence" begin
    # Reset tables
    SyncList.db_execute("DELETE FROM items;")
    SyncList.db_execute("DELETE FROM lists;")
    SyncList.db_execute("DELETE FROM sessions;")

    # Setup session
    token = "test_reorder_token"
    SyncList.db_execute("INSERT INTO sessions (token, username) VALUES (?, ?);", (token, "stefan"))

    # Create a list
    SyncList.db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", ("Reorder List", "stefan", 0))
    lists = SyncList.get_lists_for_user("stefan")
    list_id = lists[1]["id"]

    # Insert items using standard insert route (this will set positions)
    req1 = SyncList.HTTP.Request("POST", "/lists/$(list_id)/items", ["Cookie" => "session_id=$(token)"], "name=Item A")
    SyncList.internalrequest(req1)
    req2 = SyncList.HTTP.Request("POST", "/lists/$(list_id)/items", ["Cookie" => "session_id=$(token)"], "name=Item B")
    SyncList.internalrequest(req2)
    req3 = SyncList.HTTP.Request("POST", "/lists/$(list_id)/items", ["Cookie" => "session_id=$(token)"], "name=Item C")
    SyncList.internalrequest(req3)

    # Verify initial positions are A, B, C
    lists = SyncList.get_lists_for_user("stefan")
    items = lists[1]["items"]
    @test length(items) == 3
    @test items[1]["name"] == "Item A"
    @test items[2]["name"] == "Item B"
    @test items[3]["name"] == "Item C"

    # Get IDs
    id_a = items[1]["id"]
    id_b = items[2]["id"]
    id_c = items[3]["id"]

    # Perform a reorder request to change order to B, C, A
    reorder_body = "ids=$(id_b),$(id_c),$(id_a)"
    reorder_req = SyncList.HTTP.Request("POST", "/lists/$(list_id)/reorder", ["Cookie" => "session_id=$(token)", "Content-Type" => "application/x-www-form-urlencoded"], reorder_body)
    res = SyncList.internalrequest(reorder_req)
    @test res.status == 200

    # Retrieve items and check new order
    lists = SyncList.get_lists_for_user("stefan")
    items = lists[1]["items"]
    @test length(items) == 3
    @test items[1]["name"] == "Item B"
    @test items[2]["name"] == "Item C"
    @test items[3]["name"] == "Item A"
end

@testset "Edit List Sharing and Renaming Restrictions" begin
    # Reset/prepare tables
    SyncList.db_execute("DELETE FROM lists;")
    SyncList.db_execute("DELETE FROM sessions;")
    
    # Set up session tokens for owner and non-owner
    owner_token = "owner_session_token"
    non_owner_token = "non_owner_session_token"
    SyncList.db_execute("INSERT INTO sessions (token, username) VALUES (?, ?);", (owner_token, "stefan"))
    SyncList.db_execute("INSERT INTO sessions (token, username) VALUES (?, ?);", (non_owner_token, "alice"))
    
    # 1. Create a shared list owned by stefan
    SyncList.db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", ("Stefan's Shared List", "stefan", 1))
    
    # Get ID
    lists = SyncList.db_query("SELECT id FROM lists WHERE name = 'Stefan''s Shared List';")
    list_id = lists[1]["id"]
    
    # 2. Check the GET edit request for owner
    get_owner_req = SyncList.HTTP.Request("GET", "/lists/$(list_id)/edit", ["Cookie" => "session_id=$(owner_token)"])
    owner_res = SyncList.internalrequest(get_owner_req)
    @test owner_res.status == 200
    owner_html = String(owner_res.body)
    @test occursin("Stefan&#39;s Shared List", owner_html)
    @test occursin("edit-list-shared", owner_html) # switch is rendered for owner
    
    # 3. Check the GET edit request for non-owner
    get_non_owner_req = SyncList.HTTP.Request("GET", "/lists/$(list_id)/edit", ["Cookie" => "session_id=$(non_owner_token)"])
    non_owner_res = SyncList.internalrequest(get_non_owner_req)
    @test non_owner_res.status == 200
    non_owner_html = String(non_owner_res.body)
    @test occursin("Stefan&#39;s Shared List", non_owner_html)
    @test !occursin("edit-list-shared", non_owner_html) # switch is NOT rendered for non-owner
    
    # 4. POST edit by owner (turn it to private, rename to "Stefan's Private List")
    post_owner_body = "name=Stefan's Private List&is_shared=0"
    post_owner_req = SyncList.HTTP.Request("POST", "/lists/$(list_id)/edit", ["Cookie" => "session_id=$(owner_token)", "Content-Type" => "application/x-www-form-urlencoded"], post_owner_body)
    res = SyncList.internalrequest(post_owner_req)
    @test res.status == 200
    
    # Verify DB state updated
    db_list = SyncList.db_query("SELECT name, is_shared FROM lists WHERE id = ?;", (list_id,))[1]
    @test db_list["name"] == "Stefan's Private List"
    @test db_list["is_shared"] == 0
    
    # 5. Bring it back to shared so non-owner has access
    SyncList.db_execute("UPDATE lists SET is_shared = 1 WHERE id = ?;", (list_id,))
    
    # 6. POST edit by non-owner (rename list to "Hacked List Name", try to turn it to private)
    post_non_owner_body = "name=Hacked List Name&is_shared=0"
    post_non_owner_req = SyncList.HTTP.Request("POST", "/lists/$(list_id)/edit", ["Cookie" => "session_id=$(non_owner_token)", "Content-Type" => "application/x-www-form-urlencoded"], post_non_owner_body)
    res = SyncList.internalrequest(post_non_owner_req)
    @test res.status == 200
    
    # Verify DB state: name should change, but is_shared should NOT change (stays 1)
    db_list = SyncList.db_query("SELECT name, is_shared FROM lists WHERE id = ?;", (list_id,))[1]
    @test db_list["name"] == "Hacked List Name"
    @test db_list["is_shared"] == 1
end

@testset "Autosuggestion and Admin Panel" begin
    # 1. Clean the autosuggestions and sessions tables, or just verify the default German grocery items are seeded
    suggestions = SyncList.db_query("SELECT name FROM autosuggestions;")
    @test length(suggestions) >= 20
    @test any(s -> s["name"] == "Butter", suggestions)
    @test any(s -> s["name"] == "Milch", suggestions)
    @test any(s -> s["name"] == "Kaffee", suggestions)

    # 2. Add a new item to a list and verify it automatically gets collected in autosuggestions
    # Reset lists/items
    SyncList.db_execute("DELETE FROM items;")
    SyncList.db_execute("DELETE FROM lists;")
    SyncList.db_execute("DELETE FROM sessions;")

    token = "test_autosuggest_token"
    SyncList.db_execute("INSERT INTO sessions (token, username) VALUES (?, ?);", (token, "stefan"))

    SyncList.db_execute("INSERT INTO lists (name, owner, is_shared) VALUES (?, ?, ?);", ("My Grocery List", "stefan", 0))
    lists = SyncList.get_lists_for_user("stefan")
    list_id = lists[1]["id"]

    # Insert an item "Milchreis"
    req_item = SyncList.HTTP.Request("POST", "/lists/$(list_id)/items", ["Cookie" => "session_id=$(token)"], "name=Milchreis")
    res_item = SyncList.internalrequest(req_item)
    @test res_item.status == 200

    # Verify "Milchreis" is now in autosuggestions (case-insensitive check works)
    sug_exists = SyncList.db_query("SELECT COUNT(*) as count FROM autosuggestions WHERE name = 'Milchreis';")
    @test sug_exists[1]["count"] == 1

    # Insert a duplicate "milchreis" (different case) and verify it is NOT added as a duplicate
    # (collated case-insensitively, so it ignores or overrides)
    SyncList.db_execute("INSERT OR IGNORE INTO autosuggestions (name) VALUES (?);", ("milchreis",))
    sug_exists_lower = SyncList.db_query("SELECT name FROM autosuggestions WHERE name = 'Milchreis' OR name = 'milchreis';")
    @test length(sug_exists_lower) == 1

    # 3. Test Admin Panel Routes
    # GET /admin should render the suggestions
    admin_req = SyncList.HTTP.Request("GET", "/admin", ["Cookie" => "session_id=$(token)"])
    admin_res = SyncList.internalrequest(admin_req)
    @test admin_res.status == 200
    admin_html = String(admin_res.body)
    @test occursin("Milchreis", admin_html)

    # POST /admin/suggestions adds a new item
    add_req = SyncList.HTTP.Request("POST", "/admin/suggestions", ["Cookie" => "session_id=$(token)"], "name=Apfelsaft")
    add_res = SyncList.internalrequest(add_req)
    @test add_res.status == 303 # Redirects to /admin

    sug_apfel = SyncList.db_query("SELECT id FROM autosuggestions WHERE name = 'Apfelsaft';")
    @test !isempty(sug_apfel)
    sug_apfel_id = sug_apfel[1]["id"]

    # DELETE /admin/suggestions/{id} deletes the item
    del_req = SyncList.HTTP.Request("DELETE", "/admin/suggestions/$(sug_apfel_id)", ["Cookie" => "session_id=$(token)"])
    del_res = SyncList.internalrequest(del_req)
    @test del_res.status == 303 # Redirects to /admin

    # Verify Apfelsaft is deleted
    sug_apfel_deleted = SyncList.db_query("SELECT COUNT(*) as count FROM autosuggestions WHERE name = 'Apfelsaft';")
    @test sug_apfel_deleted[1]["count"] == 0
end
