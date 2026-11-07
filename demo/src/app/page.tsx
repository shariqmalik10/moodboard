import { CareNotes } from "@/components/CareNotes";
import { GardenerStack } from "@/components/GardenerStack";
import { LeafRating } from "@/components/LeafRating";
import { MistToggle } from "@/components/MistToggle";
import { PlantCard } from "@/components/PlantCard";
import { PlantSearch } from "@/components/PlantSearch";
import { RoomTabs } from "@/components/RoomTabs";
import { SortMenu } from "@/components/SortMenu";
import { SunStepper } from "@/components/SunStepper";
import { ThirstMeter } from "@/components/ThirstMeter";
import { WateredToast } from "@/components/WateredToast";
import { WaterButton } from "@/components/WaterButton";
import { WeekPlan } from "@/components/WeekPlan";

const PLANTS = ["Monstera", "Fiddle leaf fig", "Snake plant", "Pothos", "Calathea"];

export default function Home() {
  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-10 px-6 py-14">
      <header className="flex items-end justify-between gap-6">
        <div className="flex flex-col gap-2">
          <h1 className="font-display text-[44px] leading-none">Greenhouse</h1>
          <p className="text-loam">Water what&apos;s thirsty, and nothing else.</p>
        </div>
        <GardenerStack names={["Ada", "Bo", "Cy", "Dee", "Eli"]} />
      </header>
      <div className="flex flex-wrap items-center gap-4">
        <RoomTabs rooms={["Kitchen", "Bedroom", "Balcony"]} />
        <SortMenu options={["Thirstiest", "Name", "Room"]} />
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <PlantCard name="Monstera" room="Kitchen window" dryFor={6} thirstyAfter={7} />
        <PlantCard name="Pothos" room="Bookshelf" dryFor={2} thirstyAfter={10} />
      </div>
      <div className="flex flex-wrap gap-4">
        <WaterButton plant="Calathea" />
        <WateredToast plant="Pothos" />
      </div>
      <div className="flex flex-wrap gap-4">
        <ThirstMeter label="Thirst" level={3} />
        <SunStepper hours={6} />
        <MistToggle label="Morning mist" detail="A light spray at 8 am" on />
        <WeekPlan waterOn={[0, 3]} />
        <LeafRating label="How it looks this week" leaves={4} />
      </div>
      <div className="flex flex-wrap gap-4">
        <PlantSearch placeholder="Find a plant" plants={PLANTS} />
        <CareNotes
          notes={[
            { title: "Light", body: "Bright, indirect light. A metre from a south window is plenty." },
            { title: "Water", body: "When the top two centimetres of soil are dry. Less in winter." },
            { title: "Leaves", body: "Wipe them once a month so they can breathe." },
          ]}
        />
      </div>
    </main>
  );
}
