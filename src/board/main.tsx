import { createRoot } from "react-dom/client";
import "@fontsource-variable/newsreader/opsz.css";
import { Board } from "./Board";
import "./board.css";

createRoot(document.getElementById("root") as HTMLElement).render(<Board />);
