/// Uma peça de um template de nomeação: um token (com modificadores) ou texto literal.
public enum TemplateSegment: Equatable, Sendable {
    case token(name: String, modifiers: [String])
    case literal(String)
}
