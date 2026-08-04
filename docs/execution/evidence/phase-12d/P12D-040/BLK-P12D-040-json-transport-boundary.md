# BLK-P12D-040: JSON transport must not reuse strict internal scalar parsing

Status: resolved locally

The focused route test twice returned HTTP 422 before reaching the default-off branch. The first
failure showed that a strict public request model rejects JSON UUID/date/Decimal/list values after
FastAPI has decoded them to a Python mapping. Removing strict mode only from the parent request left
the same failure in the nested strict patch model, which exposed the complete root cause: the public
wire DTO and the strict internal Domain Command are different trust boundaries.

Impact was limited to the unmounted candidate route; service calls and database writes were zero.
The complete repair introduces a closed, non-authoritative JSON transport patch DTO and constructs
the strict internal command from its validated date, Decimal and tuple values. Extra fields remain
forbidden, server context remains authoritative, and the internal contract is unchanged.

Rollback is removal of the unmounted candidate router. Recovery condition is five focused route and
content-leak tests passing without warning, including valid JSON, client-authority rejection,
default-off behavior, server-context binding and receipt lookup. That condition is satisfied.
