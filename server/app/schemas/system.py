from pydantic import BaseModel


class HealthOut(BaseModel):
    status: str


class ServerInfoOut(BaseModel):
    name: str
    version: str
    api_version: int
    public_url: str
