"""End-to-end tests of the two required endpoints."""

from __future__ import annotations

from tests.conftest import BUCKET, PNG_1PX, TABLE, avatar


def test_list_users_is_empty_array_on_a_fresh_table(client) -> None:
    response = client.get("/users")
    assert response.status_code == 200
    assert response.json() == []


def test_create_user_returns_the_expected_payload(client) -> None:
    response = client.post(
        "/user",
        data={"name": "Test User", "email": "test-user@prima.it"},
        files=avatar(),
    )
    assert response.status_code == 201

    body = response.json()
    assert set(body) == {"avatar_url", "email", "name"}
    assert body["name"] == "Test User"
    assert body["email"] == "test-user@prima.it"
    assert body["avatar_url"].startswith(f"https://{BUCKET}.s3.us-east-1.amazonaws.com/avatars/")


def test_created_user_is_listed_with_the_documented_shape(client) -> None:
    client.post(
        "/user",
        data={"name": "Test User", "email": "test-user@prima.it"},
        files=avatar(),
    )
    listed = client.get("/users").json()

    assert isinstance(listed, list) and len(listed) == 1
    assert sorted(listed[0]) == ["avatar_url", "email", "name"]


def test_item_is_stored_in_dynamodb_in_the_expected_format(client, aws) -> None:
    client.post(
        "/user",
        data={"name": "Test User", "email": "test-user@prima.it"},
        files=avatar(),
    )
    items = aws["dynamodb"].scan(TableName=TABLE)["Items"]

    assert len(items) == 1
    item = items[0]
    assert item["name"] == {"S": "Test User"}
    assert item["email"] == {"S": "test-user@prima.it"}
    assert item["avatar_url"]["S"].endswith(".png")


def test_avatar_object_is_uploaded_to_s3(client, aws) -> None:
    body = client.post(
        "/user",
        data={"name": "Test User", "email": "test-user@prima.it"},
        files=avatar(),
    ).json()

    key = body["avatar_url"].split(".amazonaws.com/", 1)[1]
    stored = aws["s3"].get_object(Bucket=BUCKET, Key=key)
    assert stored["Body"].read() == PNG_1PX
    assert stored["ContentType"] == "image/png"


def test_pagination_cursor_walks_the_whole_table(client) -> None:
    for index in range(3):
        client.post(
            "/user",
            data={"name": f"User {index}", "email": f"user{index}@prima.it"},
            files=avatar(),
        )

    first = client.get("/users", params={"limit": 2})
    assert len(first.json()) == 2
    cursor = first.headers["X-Next-Cursor"]

    second = client.get("/users", params={"limit": 2, "cursor": cursor})
    assert len(second.json()) == 1
    assert "X-Next-Cursor" not in second.headers
