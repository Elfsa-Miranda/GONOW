"""Typed specifications for the three approved read-only itinerary tools."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class GeoPoint(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class PoiSearchArgs(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    keyword: str = Field(min_length=1, max_length=100)
    city_code: str = Field(pattern=r"^[A-Z0-9-]{2,16}$")
    limit: int = Field(default=5, ge=1, le=20)


class RoutePlanArgs(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    origin: GeoPoint
    destination: GeoPoint
    mode: Literal["walking", "driving", "transit"]


class WeatherCurrentArgs(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    city_code: str = Field(pattern=r"^[A-Z0-9-]{2,16}$")
    units: Literal["metric"] = "metric"


ToolArgs = PoiSearchArgs | RoutePlanArgs | WeatherCurrentArgs


@dataclass(frozen=True, slots=True)
class ToolSpec:
    name: str
    version: str
    argument_model: type[BaseModel]
    max_attempts: int
    timeout_seconds: float
    max_result_bytes: int
    read_only: bool = True

    def __post_init__(self) -> None:
        if (
            self.max_attempts not in {1, 2}
            or self.timeout_seconds <= 0
            or self.max_result_bytes < 1
            or not self.read_only
        ):
            raise ValueError("tool.spec_invalid")
