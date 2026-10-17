@ECHO OFF
cd ..
powershell.exe .\tools\train.ps1 -Mode train -ExperimentCount 4 -MaxWorkers 4 -PopulationSize 8 -Generations 10 -OutputDirectory training\results\full-search -StartWeightsPath training\results\current\best-weights.lua -PlayerLogs latest
PAUSE