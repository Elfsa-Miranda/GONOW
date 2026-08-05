"""Accept synchronous test resolvers and asynchronous production authentication."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
import inspect

from fastapi import Request

from app.auth.context import RequestContext


ContextResolver = Callable[[Request], RequestContext | Awaitable[RequestContext]]


async def resolve_request_context(
    resolver: ContextResolver, request: Request
) -> RequestContext:
    value = resolver(request)
    if inspect.isawaitable(value):
        return await value
    return value
