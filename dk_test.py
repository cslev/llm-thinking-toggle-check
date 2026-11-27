import os
import dk
from dotenv import load_dotenv

load_dotenv()

BASE_URL = f"{os.environ['LLM_OPENAI_API_URL']}/v1"
API_KEY = os.environ["LLM_OPENAI_API_KEY"]
MODEL = os.environ["LLM_OPENAI_MODEL"]


dk.configure(
    endpoint="openai",
    base_url=BASE_URL,
    api_key=API_KEY,
    model=MODEL,
)

# res = dk.solve("captchas/chi.png")
res = dk.solve("captchas/15.png")
res = dk.solve("captchas/rkch.png")