local nk = require("nakama")

-- Create an authoritative match when the matchmaker finds exactly two
-- Faceoff players. Match state and damage are owned by faceoff_match.lua.
nk.register_matchmaker_matched(function(context, matched_users)
    if #matched_users ~= 2 then
        return nil
    end
    return nk.match_create("faceoff_match", { expected_users = matched_users })
end)

nk.register_rpc(function(context, payload)
    local data = {}
    if payload and payload ~= "" then
        data = nk.json_decode(payload)
    end
    return nk.json_encode({
        match_id = nk.match_create("faceoff_match", data),
    })
end, "faceoff_create_match")
