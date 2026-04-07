from src.logic import compute_candidate_x


def test_first_round_without_comment() -> None:
    result = compute_candidate_x(current_x=1, comments="", attempt=1)

    assert result == {
        "candidate_x": 2.0,
        "attempt": 1,
        "comment_in": "",
    }


def test_reject_comment_round_trip() -> None:
    result = compute_candidate_x(current_x=3.2, comments="数值不符合，打回", attempt=2)

    assert result["candidate_x"] == 4.2
    assert result["comment_in"] == "数值不符合，打回"
    assert result["attempt"] == 2


def test_invalid_input_raises() -> None:
    try:
        compute_candidate_x(current_x=None, comments="", attempt=1)
    except ValueError as exc:
        assert "current_x is required" in str(exc)
    else:
        raise AssertionError("expected ValueError for missing current_x")
