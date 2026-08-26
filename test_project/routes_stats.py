from fastapi import APIRouter

import stats


def build_stats_router(store) -> APIRouter:
    """Build the stats router bound to ``store``."""
    router = APIRouter()

    @router.get("/stats/summary")
    def get_stats_summary() -> dict[str, int]:
        return stats.compute_stats(store.list())

    return router
