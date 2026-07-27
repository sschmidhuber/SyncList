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
