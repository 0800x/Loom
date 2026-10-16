package main

import "charm.land/lipgloss/v2"

// init applies the Loom coral and charcoal palette with readable SSH contrast.
func init() {
	var (
		brand       = lipgloss.Color("#A8422C")
		brandBright = lipgloss.Color("#F4A28C")
		green       = lipgloss.Color("#34D399")
		yellow      = lipgloss.Color("#FBBF24")
		red         = lipgloss.Color("#FB7185")
		text        = lipgloss.Color("#F8FAFC")
		muted       = lipgloss.Color("#94A3B8")
		panel       = lipgloss.Color("#1B1C21")
		panelSoft   = lipgloss.Color("#111318")
		border      = lipgloss.Color("#464247")
	)

	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(text)
	dimStyle = lipgloss.NewStyle().Foreground(muted)
	goodStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#052E16")).Background(green).Padding(0, 1)
	warnStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#422006")).Background(yellow).Padding(0, 1)
	badStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#4C0519")).Background(red).Padding(0, 1)
	selStyle = lipgloss.NewStyle().Bold(true).Foreground(text).Background(brand).Padding(0, 1)
	panelStyle = lipgloss.NewStyle().Padding(1, 2).Foreground(text)
	navStyle = lipgloss.NewStyle().Width(25).Padding(1, 1).MarginRight(1).Foreground(text).Background(panelSoft).Border(lipgloss.RoundedBorder()).BorderForeground(brandBright)
	contentStyle = lipgloss.NewStyle().Width(74).Padding(1, 2).Foreground(text).Background(panel).Border(lipgloss.RoundedBorder()).BorderForeground(border)
}
