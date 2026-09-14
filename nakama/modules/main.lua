local nk = require("nakama")

-- Create an authoritative match when the matchmaker finds exactly two
-- Faceoff players. Match state and damage are owned by faceoff_match.lua.
nk.register_matchmaker_matched(function(context, matched_users)
    if #matched_users ~= 2 then
        return nil
    end
    local match_id = nk.match_create("faceoff_match", { expected_users = matched_users })
    return match_id
end)

-- Social RPCs are registered when social.lua is loaded by Nakama.
