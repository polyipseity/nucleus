# Fixture: correct service log capture — one file per stream.
& 'fixture-bin' --port 1234 1>> '/logs/fixture/stdout.log' 2>> '/logs/fixture/stderr.log'
