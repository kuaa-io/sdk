package kuaa

import "iter"

// Page is one page of a list, and where the next one starts.
type Page[T any] struct {
	Items []T
	// NextCursor is the cursor of the next page, or nil on the last one.
	NextCursor *string
	// HasMore says another page follows.
	HasMore bool
}

// iterate walks pages from cursor until the last one, yielding every item and
// stopping at the first error.
func iterate[T any](fetch func(cursor string) (*Page[T], error), cursor string) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		for {
			page, err := fetch(cursor)
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			for _, item := range page.Items {
				if !yield(item, nil) {
					return
				}
			}
			if !page.HasMore || page.NextCursor == nil || *page.NextCursor == "" {
				return
			}
			cursor = *page.NextCursor
		}
	}
}
