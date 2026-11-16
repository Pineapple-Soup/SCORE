import { Behavior } from "@/types/behavior";

export type Segment = {
  behavior: Behavior;
  startTime: number;
  endTime: number | null;
  notes?: string;
};

export type Annotation = {
  id: string;
  assignmentId: string;
  segments: Segment[];
  submitted: boolean;
  submittedAt: string | null;
  updatedAt: string | null;
};
