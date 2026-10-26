package ext

import (
	"strings"

	"github.com/andybalholm/cascadia"
	"github.com/dop251/goja"
	"golang.org/x/net/html"
)

// htmlObject 提供基于 x/net/html + cascadia 的只读 DOM API：
//
//	hg.html.parse(text) -> Document
//	hg.html.findFirst(node, css) / findAll(node, css)
//	hg.html.attr(node, name) / text(node) / inner(node) / html(node)
func htmlObject(vm *goja.Runtime) *goja.Object {
	object := vm.NewObject()
	_ = object.Set("parse", func(call goja.FunctionCall) goja.Value {
		text := toString(call.Argument(0))
		if strings.TrimSpace(text) == "" {
			return goja.Null()
		}
		document, err := html.Parse(strings.NewReader(text))
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(wrapNode(vm, document))
	})
	_ = object.Set("findFirst", func(call goja.FunctionCall) goja.Value {
		node, selector := nodeArgument(vm, call)
		if node == nil {
			return goja.Null()
		}
		matched := cascadia.Query(node, compileSelector(vm, selector))
		if matched == nil {
			return goja.Null()
		}
		return vm.ToValue(wrapNode(vm, matched))
	})
	_ = object.Set("findAll", func(call goja.FunctionCall) goja.Value {
		node, selector := nodeArgument(vm, call)
		if node == nil {
			return vm.ToValue([]any{})
		}
		matched := cascadia.QueryAll(node, compileSelector(vm, selector))
		nodes := make([]any, 0, len(matched))
		for _, item := range matched {
			nodes = append(nodes, wrapNode(vm, item))
		}
		return vm.ToValue(nodes)
	})
	_ = object.Set("attr", func(call goja.FunctionCall) goja.Value {
		node := unwrapNode(call.Argument(0))
		if node == nil {
			return goja.Null()
		}
		return vm.ToValue(nodeAttr(node, toString(call.Argument(1))))
	})
	_ = object.Set("text", func(call goja.FunctionCall) goja.Value {
		node := unwrapNode(call.Argument(0))
		if node == nil {
			return goja.Null()
		}
		return vm.ToValue(strings.TrimSpace(nodeText(node)))
	})
	_ = object.Set("inner", func(call goja.FunctionCall) goja.Value {
		node := unwrapNode(call.Argument(0))
		if node == nil {
			return goja.Null()
		}
		var builder strings.Builder
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			builder.WriteString(nodeOuterHTML(child))
		}
		return vm.ToValue(builder.String())
	})
	_ = object.Set("html", func(call goja.FunctionCall) goja.Value {
		node := unwrapNode(call.Argument(0))
		if node == nil {
			return goja.Null()
		}
		return vm.ToValue(nodeOuterHTML(node))
	})
	return object
}

// nodeView 是暴露给 JS 的只读节点包装（仅持有指针，方法在宿主侧实现）。
type nodeView struct{ node *html.Node }

func wrapNode(vm *goja.Runtime, node *html.Node) *nodeView {
	if node == nil {
		return nil
	}
	return &nodeView{node: node}
}

func nodeArgument(vm *goja.Runtime, call goja.FunctionCall) (*html.Node, string) {
	node := unwrapNode(call.Argument(0))
	selector := toString(call.Argument(1))
	return node, selector
}

func unwrapNode(value goja.Value) *html.Node {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil
	}
	if view, ok := value.Export().(*nodeView); ok {
		return view.node
	}
	return nil
}

func compileSelector(vm *goja.Runtime, selector string) cascadia.Matcher {
	compiled, err := cascadia.Compile(selector)
	if err != nil {
		panic(vm.NewGoError(err))
	}
	return compiled
}

func nodeAttr(node *html.Node, name string) string {
	for _, attribute := range node.Attr {
		if strings.EqualFold(attribute.Key, name) {
			return attribute.Val
		}
	}
	return ""
}

func nodeText(node *html.Node) string {
	switch node.Type {
	case html.TextNode:
		return node.Data
	case html.ElementNode:
		var builder strings.Builder
		var walk func(*html.Node)
		walk = func(current *html.Node) {
			if current.Type == html.TextNode {
				builder.WriteString(current.Data)
				return
			}
			for child := current.FirstChild; child != nil; child = child.NextSibling {
				if child.Type != html.ElementNode || child.Data != "script" && child.Data != "style" {
					walk(child)
				}
			}
		}
		walk(node)
		return builder.String()
	}
	return ""
}

func nodeOuterHTML(node *html.Node) string {
	var builder strings.Builder
	_ = html.Render(&builder, node)
	return builder.String()
}
