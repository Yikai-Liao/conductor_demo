export interface ConductorTask {
  inputData?: Record<string, unknown>;
  referenceTaskName?: string;
  seq?: number;
  startTime?: number;
  status?: string;
  taskId: string;
  taskType?: string;
  updateTime?: number;
  workflowInstanceId: string;
}

export interface ConductorWorkflow {
  status?: string;
  tasks?: ConductorTask[];
  workflowId?: string;
}

export interface WorkflowSearchResponse {
  results?: Array<{ workflowId?: string }>;
  totalHits?: number;
}

export interface UpdateTaskPayload {
  outputData?: Record<string, unknown>;
  reasonForIncompletion?: string;
  status: string;
  taskId: string;
  workflowInstanceId: string;
}

export class ConductorClient {
  constructor(private readonly baseUrl: string) {}

  async getTask(taskId: string): Promise<ConductorTask> {
    return this.requireJson<ConductorTask>(`/tasks/${encodeURIComponent(taskId)}`);
  }

  async getWorkflow(workflowId: string): Promise<ConductorWorkflow> {
    return this.requireJson<ConductorWorkflow>(
      `/workflow/${encodeURIComponent(workflowId)}?includeTasks=true`,
    );
  }

  async searchWorkflows(query: string, size: number): Promise<WorkflowSearchResponse> {
    const params = new URLSearchParams({
      query,
      size: String(size),
      start: "0",
    });

    return this.requireJson<WorkflowSearchResponse>(`/workflow/search?${params.toString()}`);
  }

  async updateTask(payload: UpdateTaskPayload): Promise<unknown> {
    return this.requireJson("/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  }

  private async requireJson<T>(path: string, init?: RequestInit): Promise<T> {
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
      throw new Error(`Conductor ${init?.method ?? "GET"} ${path} returned empty response`);
    }

    return JSON.parse(text) as T;
  }
}
