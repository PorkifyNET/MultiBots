local Playback = dofile("bot/playback.lua")

assert(Playback.hands_to_play(4, 4) == 0, "bot must wait while hand counts are equal")
assert(Playback.hands_to_play(4, 3) == 1, "bot should answer one player hand")
assert(Playback.hands_to_play(3, 3) == 0, "bot must wait after catching up")
assert(Playback.hands_to_play(4, 2) == 2, "bot should catch up when multiple player hands are consumed")
assert(Playback.hands_to_play(1, 0) == 1, "bot should answer the player's final hand")
assert(Playback.hands_to_play(0, 0) == 0, "exhausted bot cannot play again")

print("playback_spec: ok")
