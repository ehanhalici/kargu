//! Measuring how deeply control flow nests inside one function body.

use syn::{Block, Expr, visit::Visit};

/// Deepest nesting of branches, loops and closures in `block`.
pub fn depth(block: &Block) -> usize {
    let mut meter = Meter {
        current: 0,
        deepest: 0,
    };
    meter.visit_block(block);
    meter.deepest
}

struct Meter {
    current: usize,
    deepest: usize,
}

impl Meter {
    fn nested(&mut self, walk: impl FnOnce(&mut Self)) {
        self.current = self.current.saturating_add(1);
        self.deepest = self.deepest.max(self.current);
        walk(self);
        self.current = self.current.saturating_sub(1);
    }

    /// A braced arm or closure body belongs to its `match`/closure level.
    fn visit_body(&mut self, body: &Expr) {
        match body {
            Expr::Block(block) => self.visit_block(&block.block),
            other => self.visit_expr(other),
        }
    }

    fn visit_arms(&mut self, choice: &syn::ExprMatch) {
        self.visit_expr(&choice.expr);
        for arm in &choice.arms {
            if let Some((_, guard)) = &arm.guard {
                self.visit_expr(guard);
            }
            self.visit_body(&arm.body);
        }
    }

    /// An `else if` continues its chain; it is not one level deeper.
    fn visit_if_chain(&mut self, node: &syn::ExprIf) {
        self.visit_expr(&node.cond);
        self.visit_block(&node.then_branch);
        match node.else_branch.as_ref().map(|(_, branch)| branch.as_ref()) {
            Some(Expr::If(next)) => self.visit_if_chain(next),
            Some(other) => self.visit_expr(other),
            None => {}
        }
    }
}

impl<'ast> Visit<'ast> for Meter {
    fn visit_expr(&mut self, node: &'ast Expr) {
        match node {
            Expr::If(chain) => self.nested(|meter| meter.visit_if_chain(chain)),
            Expr::Match(choice) => self.nested(|meter| meter.visit_arms(choice)),
            Expr::Closure(closure) => self.nested(|meter| meter.visit_body(&closure.body)),
            Expr::Loop(_)
            | Expr::While(_)
            | Expr::ForLoop(_)
            | Expr::Block(_)
            | Expr::Unsafe(_)
            | Expr::Async(_) => self.nested(|meter| syn::visit::visit_expr(meter, node)),
            _ => syn::visit::visit_expr(self, node),
        }
    }

    /// Nested items are judged on their own, not as part of this body.
    fn visit_item(&mut self, _node: &'ast syn::Item) {}
}
