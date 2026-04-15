from src.logic import compute_candidate_x


def test_first_round_without_comment() -> None:
    result = compute_candidate_x(current_x=1, comments="", attempt=1)

    assert result == {
        "candidate_x": 2.0,
        "attempt": 1,
        "comment_in": "",
    }


def test_reject_comment_round_trip() -> None:
    comment = "资料不完整，退回补充 / rejected"
    result = compute_candidate_x(current_x=3.2, comments=comment, attempt=2)

    assert result["candidate_x"] == 4.2
    assert result["comment_in"] == comment
    assert result["attempt"] == 2


def test_invalid_input_raises() -> None:
    try:
        compute_candidate_x(current_x=None, comments="", attempt=1)
    except ValueError as exc:
        assert "current_x is required" in str(exc)
    else:
        raise AssertionError("expected ValueError for missing current_x")
