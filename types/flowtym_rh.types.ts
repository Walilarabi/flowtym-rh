// =====================================================================
// Flowtym · Module RH/Staff — Types TypeScript alignés sur Supabase
// Tables : staff_departments, staff_roles, employees, employee_contracts,
//          employee_documents, staff_planning, staff_absences
// Convention Supabase : Row (lecture) / Insert (création) / Update (maj)
// =====================================================================

/** Codes de statut du planning (légende RH) */
export type PlanningStatus = 'P' | 'CP' | 'RTT' | 'MAL' | 'MAT' | 'CSS' | 'AE' | 'F';
/** Codes d'absence (période) — P n'est pas une absence */
export type AbsenceType = Exclude<PlanningStatus, 'P'>;
export type ContractType = 'CDI' | 'CDD' | 'Extra' | 'Stage' | 'Interim' | 'Apprentissage';
export type DocumentType = 'cni' | 'passport' | 'sejour' | 'rib' | 'domicile' | 'hebergement' | 'contrat' | 'autre';
export type DocumentStatus = 'provided' | 'missing' | 'expired' | 'pending';
export type AbsenceStatus = 'pending' | 'approved' | 'rejected' | 'cancelled';
export type PlanningDuration = 0.5 | 1.0;

export interface StaffDepartment {
  id: string;
  hotel_id: string;
  name: string;
  sort_order: number;
  created_at: string;
}

export interface StaffRole {
  id: string;
  hotel_id: string;
  name: string;
  department_id: string | null;
  created_at: string;
}

export interface Employee {
  id: string;
  hotel_id: string;
  first_name: string;
  last_name: string;
  role: string | null;
  role_id: string | null;
  department: string | null;
  department_id: string | null;
  contract_type: ContractType;
  hire_date: string | null;       // date (YYYY-MM-DD)
  rest_days: number[];            // 0=dimanche … 6=samedi
  phone: string | null;
  email: string | null;
  address: string | null;
  emergency_contact: string | null;
  active: boolean;
  created_at: string;
  updated_at: string;
}

export interface EmployeeContract {
  id: string;
  hotel_id: string;
  employee_id: string;
  type: ContractType;
  start_date: string | null;
  end_date: string | null;
  weekly_hours: number | null;
  gross_monthly_salary: number | null;
  signed: boolean;
  document_url: string | null;
  created_at: string;
}

export interface EmployeeDocument {
  id: string;
  hotel_id: string;
  employee_id: string;
  doc_type: DocumentType;
  status: DocumentStatus;
  file_url: string | null;
  expires_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface StaffPlanning {
  id: string;
  hotel_id: string;
  employee_id: string;
  day: string;                    // date (YYYY-MM-DD)
  status: PlanningStatus;
  duration: PlanningDuration;
  note: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface StaffAbsence {
  id: string;
  hotel_id: string;
  employee_id: string;
  type: AbsenceType;
  start_date: string;
  end_date: string;
  days: number | null;
  status: AbsenceStatus;
  reason: string | null;
  created_at: string;
  updated_at: string;
}

export interface VStaffMonthSummary {
  hotel_id: string;
  employee_id: string;
  month: string;                  // premier jour du mois (date)
  worked_days: number;
  cp_days: number;
  other_absences: number;
  entries: number;
}

// ---- Helpers Insert/Update (champs auto-générés optionnels) ----
type Auto = 'id' | 'created_at' | 'updated_at';
export type Insert<T, K extends keyof T = never> = Omit<T, Auto | K> & Partial<Pick<T, Extract<Auto, keyof T>>>;
export type Update<T> = Partial<Omit<T, 'id' | 'hotel_id' | 'created_at'>>;

export type EmployeeInsert        = Insert<Employee>;
export type EmployeeUpdate        = Update<Employee>;
export type StaffPlanningInsert   = Insert<StaffPlanning>;
export type StaffPlanningUpdate   = Update<StaffPlanning>;
export type StaffAbsenceInsert    = Insert<StaffAbsence>;
export type EmployeeDocumentInsert= Insert<EmployeeDocument>;
export type EmployeeContractInsert= Insert<EmployeeContract>;

// ---- Sous-ensemble Database (compatible @supabase/supabase-js) ----
export interface RHDatabase {
  public: {
    Tables: {
      staff_departments: { Row: StaffDepartment; Insert: Insert<StaffDepartment>; Update: Update<StaffDepartment> };
      staff_roles:       { Row: StaffRole;       Insert: Insert<StaffRole>;       Update: Update<StaffRole> };
      employees:         { Row: Employee;        Insert: EmployeeInsert;          Update: EmployeeUpdate };
      employee_contracts:{ Row: EmployeeContract;Insert: EmployeeContractInsert;  Update: Update<EmployeeContract> };
      employee_documents:{ Row: EmployeeDocument;Insert: EmployeeDocumentInsert;  Update: Update<EmployeeDocument> };
      staff_planning:    { Row: StaffPlanning;   Insert: StaffPlanningInsert;     Update: StaffPlanningUpdate };
      staff_absences:    { Row: StaffAbsence;    Insert: StaffAbsenceInsert;      Update: Update<StaffAbsence> };
    };
    Views: {
      v_staff_month_summary: { Row: VStaffMonthSummary };
    };
  };
}
