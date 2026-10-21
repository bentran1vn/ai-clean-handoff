using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

bool IsComment(SyntaxTrivia t) => t.IsKind(SyntaxKind.SingleLineCommentTrivia) || t.IsKind(SyntaxKind.MultiLineCommentTrivia) || t.IsKind(SyntaxKind.SingleLineDocumentationCommentTrivia) || t.IsKind(SyntaxKind.MultiLineDocumentationCommentTrivia);
string? line;
while ((line = Console.ReadLine()) != null)
{
    try
    {
        using var request = JsonDocument.Parse(line);
        var before = request.RootElement.GetProperty("before").GetString()!;
        var after = request.RootElement.GetProperty("after").GetString()!;
        var options = new CSharpParseOptions(LanguageVersion.Preview, DocumentationMode.Parse);
        var oldRoot = CSharpSyntaxTree.ParseText(before, options).GetRoot();
        var newRoot = CSharpSyntaxTree.ParseText(after, options).GetRoot();
        // Disabled preprocessor regions are not parsed by Roslyn; fail closed.
        if (newRoot.DescendantTrivia(descendIntoTrivia: true).Any(t => t.IsKind(SyntaxKind.DisabledTextTrivia)))
            throw new Exception("Disabled preprocessor region requires review");
        if (newRoot.GetDiagnostics().Any(d => d.Severity == DiagnosticSeverity.Error))
            throw new Exception("C# parse error; refusing cleanup");
        var budget = oldRoot.DescendantTrivia().Where(IsComment).GroupBy(t => t.ToFullString()).ToDictionary(g => g.Key, g => g.Count());
        var remove = new List<SyntaxTrivia>();
        foreach (var trivia in newRoot.DescendantTrivia().Where(IsComment))
        {
            var key = trivia.ToFullString();
            if (budget.TryGetValue(key, out var count) && count > 0) budget[key] = count - 1;
            else remove.Add(trivia);
        }
        var result = newRoot.ReplaceTrivia(remove, (original, _) => SyntaxFactory.Whitespace(new string(original.ToFullString().Select(c => c is '\r' or '\n' ? c : ' ').ToArray()))).ToFullString();
        var parsed = CSharpSyntaxTree.ParseText(result, options).GetRoot();
        var tokens = newRoot.DescendantTokens().Select(t => (t.RawKind, t.Text));
        if (!tokens.SequenceEqual(parsed.DescendantTokens().Select(t => (t.RawKind, t.Text))) || parsed.GetDiagnostics().Any(d => d.Severity == DiagnosticSeverity.Error))
            throw new Exception("Code token stream or syntax changed");
        Console.WriteLine(JsonSerializer.Serialize(new { text = result, removed = remove.Count }));
    }
    catch (Exception e) { Console.WriteLine(JsonSerializer.Serialize(new { error = e.Message })); }
}
