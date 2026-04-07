export interface ConductorTask {
  taskId: string;
  workflowInstanceId: string;
  taskType?: string;
  referenceTaskName?: string;
  status?: string;
  inputData?: Record<string, unknown>;
}

export interface UpdateTaskPayload {
  taskId: string;
  workflowInstanceId: string;
  status: string;
  outputData?: Record<string, unknown>;
  reasonForIncompletion?: string;
}

export class ConductorClient {
  constructor(private readonly baseUrl: string) {}

  async pollTask(taskType: string, workerId: string): Promise<ConductorTask | null> {
    const path = `/tasks/poll/${encodeURIComponent(taskType)}?workerid=${encodeURIComponent(workerId)}`;
    return this.requestJson<ConductorTask>(path);
  }

  async updateTask(payload: UpdateTaskPayload): Promise<unknown> {
    return this.requestJson("/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  }

  private async requestJson<T>(path: string, init?: RequestInit): Promise<T | null> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      ...init,
      headers: {
        Accept: "application/json",
        ...(init?.headers ?? {}),
      },
    });

    const text = await response.text();
    if (!response.ok) {
      throw new Error(`Conductor ${init?.method ?? "GET"} ${path} failed: ${response.status} ${text}`);
    }

    if (!text || text === "null") {
      return null;
    }

    return JSON.parse(text) as T;
  }
}
