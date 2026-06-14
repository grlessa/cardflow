import Foundation
import OffloadKit

/// Monta a linha de erro que o executável escreve no stderr, já localizada.
///
/// O prefixo ("erro:"/"error:") vem do catálogo da CLI. Os erros conhecidos
/// (CardflowRunError/CLIError/PresetError) viram uma mensagem amigável traduzida;
/// para os demais cai no `localizedDescription`/`errorDescription` do erro (cujo
/// pt-BR cravado nos enums do OffloadKit serve de fallback de dev).
public enum CLIErrorReport {
    /// Linha completa pronta pro stderr (sem o `\n` final — quem escreve adiciona).
    public static func line(for error: Error) -> String {
        "\(CLIStrings.string("cli.error.prefix")) \(message(for: error))"
    }

    /// Só a mensagem (sem prefixo), já localizada quando o erro é conhecido.
    static func message(for error: Error) -> String {
        switch error {
        case let e as CardflowRunError:
            switch e {
            case .noSpace:
                return CLIStrings.string("cli.error.noSpace")
            case .verificationFailed(let count):
                return CLIStrings.string("cli.error.verificationFailed %lld", count)
            case .sameDisk(let names):
                return CLIStrings.string("cli.error.sameDisk %@", names.joined(separator: ", "))
            }
        case let e as CLIError:
            switch e {
            case .missing(let flag):
                return CLIStrings.string("cli.error.missing %@", flag)
            case .badValue(let value):
                return CLIStrings.string("cli.error.badValue %@", value)
            }
        case let e as PresetStore.PresetError:
            switch e {
            case .unsupportedSchema(let v):
                return CLIStrings.string("cli.error.preset.unsupportedSchema %lld", v)
            case .invalidTemplate(let reason):
                // O detalhe técnico do enum (token/traversal) permanece como complemento.
                return CLIStrings.string("cli.error.preset.invalidTemplate %@", reason)
            case .fileTooLarge:
                return CLIStrings.string("cli.error.preset.fileTooLarge")
            }
        default:
            // OffloadError e erros de sistema (decode, arquivo ausente) já trazem
            // mensagem própria; aqui só repassamos o detalhe localizável do erro.
            return detail(of: error)
        }
    }

    /// Texto do erro: prefere `errorDescription` (mensagem humana dos enums), cai no `String(describing:)`.
    private static func detail(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
