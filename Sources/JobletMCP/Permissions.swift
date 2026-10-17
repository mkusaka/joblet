/// Mutating capabilities. Everything not listed here (list_jobs, get_job, read_log) is always available.
public enum Permission: String, CaseIterable, Sendable {
    case create = "--allow-create"
    case update = "--allow-update" // also covers enable/disable
    case run = "--allow-run"
    case delete = "--allow-delete"
    /// Lifts the "created by Joblet" restriction for run / enable / disable only.
    case foreignJobs = "--allow-foreign-jobs"
}

public struct ServerOptions: Sendable {
    public var permissions: Set<Permission> = []

    public init(permissions: Set<Permission> = []) {
        self.permissions = permissions
    }

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let usage = """
    Usage: joblet-mcp [flags]
    Read-only by default. Flags enable mutating tools:
      --allow-create        create_job
      --allow-update        update_job, set_job_enabled
      --allow-run           run_job
      --allow-delete        delete_job
      --allow-all           the four flags above (not --allow-foreign-jobs)
      --allow-foreign-jobs  let run_job / set_job_enabled act on jobs not created by Joblet
    """

    public static func parse(_ arguments: [String]) throws -> ServerOptions {
        var options = ServerOptions()
        for argument in arguments {
            if argument == "--allow-all" {
                options.permissions.formUnion([.create, .update, .run, .delete])
            } else if let permission = Permission(rawValue: argument) {
                options.permissions.insert(permission)
            } else {
                throw UsageError(description: "Unknown argument: \(argument)")
            }
        }
        return options
    }
}
