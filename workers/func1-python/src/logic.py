from __future__ import annotations


def normalize_attempt(value: object) -> int:
    attempt = int(value)
    if attempt < 1:
        raise ValueError("attempt must be >= 1")
    if attempt > 128:
        raise ValueError("attempt must be <= 128")
    return attempt


def compute_candidate_x(current_x: object, comments: object, attempt: object) -> dict[str, float | int | str]:
    if current_x is None:
        raise ValueError("current_x is required")

    numeric_x = float(current_x)
    normalized_attempt = normalize_attempt(attempt)
    normalized_comment = str(comments or "")
    candidate_x = round(numeric_x + 1.0, 2)

    return {
        "candidate_x": candidate_x,
        "attempt": normalized_attempt,
        "comment_in": normalized_comment,
    }
