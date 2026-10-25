# Startup scripts

Scripts placed here (`*.sh` or `*.sql`) run **every time** the database container starts, after the database is open. `*.sql` files run as `SYSDBA` in the root container; `*.sh` files are sourced by the image's start-up script as the `oracle` user.

None are needed yet. This folder must exist because `compose.yaml` mounts it; otherwise Docker would create it owned by root. The image ignores this README.
