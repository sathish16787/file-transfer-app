# file-transfer-app

## Architecture & Local Setup

- **Application Entrypoint:** `src/file_move.py` (Flask app with chunked transfer and SHA-256 verification).
- **Configuration:** Uses `FILE_TRANSFER_BASE_DIR` for environment-agnostic directory paths.
- **Testing:** Run `pytest -v` to execute tests in `tests/`.

### Run Tests Locally

```bash
pytest -v
